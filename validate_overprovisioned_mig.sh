#!/usr/bin/env bash
# Recommendation : Over-Provisioned Managed Instance Groups (fixed size MIGs)
# Source doc     : Overprovisioned  __ GCP MIG.md
# Finding reason : OVERPROVISIONED_FIXED_SIZE_MIG
#
# Detection logic:
#   1. List every managed instance group in each target project.
#   2. Skip MIGs with an autoscaler attached: those already self-adjust.
#   3. Skip MIGs created less than DAYS ago and MIGs already at target size 2 or
#      smaller.
#   4. Target size stability: compare min and max of
#      compute.googleapis.com/instance_group/size over the lookback window. A MIG
#      whose size moved at any point is skipped, because the environment is
#      already being actively resized.
#   5. Peak CPU across the group's member instances from
#      compute.googleapis.com/instance/cpu/utilization, daily buckets, ALIGN_MAX.
#   6. Peak CPU < THRESHOLD (default 30%) qualifies.
#   7. Recommended size = ceil(current size x peak CPU / TARGET), TARGET default
#      60%, floored at 2 instances so redundancy survives.
#
# Usage: validate_overprovisioned_mig.sh (-p PROJECTS | -o ORG_ID | -f FOLDER_ID) [options]
#
# Options:
#   -p PROJECTS     evaluate one project, or several as a comma-separated list
#   -o ORG_ID       evaluate every ACTIVE project under an organization
#   -f FOLDER_ID    evaluate every ACTIVE project under a folder
#   -d DAYS         lookback window and age threshold in days (default 30)
#   -u THRESHOLD    peak CPU threshold percent (default 30)
#   -t TARGET       target utilization percent used for sizing (default 60)
#   -m MIN_SIZE     never recommend fewer than this many instances (default 2)
#   -n ORG_NAME     render the Organization ID cell as "ORG_NAME (ORG_ID)"
#   -P PRICING_FILE pricing table (CSV or JSON) used for Potential Savings
#   -i SA_EMAIL     impersonate this service account for every gcloud call
#   -c CSV_FILE     also write the rows to CSV_FILE (overwrites)
#   -j              print a JSON array instead of the Markdown table
#   -F              render Region using friendly location names
#   -v              echo each gcloud invocation to stderr
#   -h              print this header and exit
#
# Exit codes: 0 success, 1 argument or dependency failure, 2 every project failed
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

for arg in "$@"; do
  if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
    awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "${BASH_SOURCE[0]}"
    exit 0
  fi
done

command -v gcloud >/dev/null 2>&1 || { echo "gcloud CLI not found on PATH" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 not found on PATH" >&2; exit 1; }

GCP_RECO_LIB_DIR="$SCRIPT_DIR" exec python3 - "$@" <<'PYTHON'
import math
import os
import sys

sys.path.insert(0, os.environ["GCP_RECO_LIB_DIR"])

from gcp_reco_lib import (
    NO_DATA,
    GcpError,
    MetricHttpError,
    MetricUnavailable,
    last_segment,
    peak,
    pct,
    run_detection,
)

CPU = "compute.googleapis.com/instance/cpu/utilization"
GROUP_SIZE = "compute.googleapis.com/instance_group/size"

# Monitoring filters have a length limit, so instance IDs are queried in chunks.
ID_CHUNK = 50


def add_arguments(parser):
    parser.add_argument("-u", dest="utilization", default="30")
    parser.add_argument("-t", dest="target", default="60")
    parser.add_argument("-m", dest="min_size", default="2")


def number(ctx, value, fallback, label):
    try:
        return float(value)
    except (TypeError, ValueError):
        ctx.warn("%s is not numeric; falling back to %s" % (label, fallback))
        return float(fallback)


def autoscaled_targets(ctx, project):
    """selfLinks of instance groups that already have an autoscaler."""
    targets = set()
    try:
        autoscalers = ctx.gcloud.run(["compute", "autoscalers", "list"], project=project) or []
    except GcpError as exc:
        ctx.warn("project %s: autoscaler list unavailable: %s" % (project, exc.summary()))
        return None
    for autoscaler in autoscalers:
        target = autoscaler.get("target")
        status = (autoscaler.get("status") or "").upper()
        if target and status != "DELETING":
            targets.add(target)
    return targets


def mig_is_autoscaled(mig, autoscaled):
    """Prefer the autoscaler list; fall back to the MIG's own fields."""
    if mig.get("autoscaler") or (mig.get("status") or {}).get("autoscaler"):
        return True
    if autoscaled is None:
        return False
    return mig.get("selfLink") in autoscaled


def size_is_stable(ctx, project, mig_name, location):
    """True when the group's size never moved across the window."""
    resource_filter = ' AND resource.labels.instance_group_name="%s"' % mig_name
    highest = ctx.metrics.points(
        project, GROUP_SIZE, resource_filter, aligner="ALIGN_MAX", alignment_period=86400
    )
    lowest = ctx.metrics.points(
        project, GROUP_SIZE, resource_filter, aligner="ALIGN_MIN", alignment_period=86400
    )
    if highest == NO_DATA or lowest == NO_DATA or not highest or not lowest:
        return None
    return math.isclose(max(highest), min(lowest), rel_tol=0.0, abs_tol=0.001)


def member_instance_ids(ctx, project, mig_name, location, regional):
    scope = ["--region", location] if regional else ["--zone", location]
    try:
        members = (
            ctx.gcloud.run(
                ["compute", "instance-groups", "managed", "list-instances", mig_name] + scope,
                project=project,
            )
            or []
        )
    except GcpError as exc:
        ctx.warn(
            "project %s: mig %s: member list unavailable: %s"
            % (project, mig_name, exc.summary())
        )
        return []
    ids = []
    for member in members:
        instance_id = member.get("id") or last_segment(member.get("instance", ""))
        if instance_id:
            ids.append(str(instance_id))
    return ids


def peak_cpu(ctx, project, instance_ids):
    """Highest CPU utilization percent seen on any member instance."""
    highest = None
    for start in range(0, len(instance_ids), ID_CHUNK):
        chunk = instance_ids[start : start + ID_CHUNK]
        joined = ",".join('"%s"' % value for value in chunk)
        resource_filter = (
            ' AND resource.type="gce_instance"'
            " AND resource.labels.instance_id = one_of(%s)" % joined
        )
        points = ctx.metrics.points(
            project, CPU, resource_filter, aligner="ALIGN_MAX", alignment_period=86400
        )
        if points == NO_DATA:
            continue
        value = peak(points)
        highest = value if highest is None else max(highest, value)
    return None if highest is None else highest * 100.0


def template_machine_type(ctx, project, template_url, cache):
    if not template_url:
        return ""
    if template_url in cache:
        return cache[template_url]
    name = last_segment(template_url)
    machine_type = ""
    try:
        detail = ctx.gcloud.run(
            ["compute", "instance-templates", "describe", name], project=project
        )
        machine_type = last_segment(((detail or {}).get("properties") or {}).get("machineType", ""))
    except GcpError as exc:
        ctx.warn(
            "project %s: template %s unavailable: %s" % (project, name, exc.summary())
        )
    cache[template_url] = machine_type
    return machine_type


def detect(ctx, project):
    threshold = number(ctx, ctx.args.utilization, 30, "THRESHOLD (-u)")
    target_utilization = number(ctx, ctx.args.target, 60, "TARGET (-t)")
    floor_size = int(number(ctx, ctx.args.min_size, 2, "MIN_SIZE (-m)"))

    migs = (
        ctx.gcloud.run(["compute", "instance-groups", "managed", "list"], project=project)
        or []
    )
    autoscaled = autoscaled_targets(ctx, project)
    if autoscaled is None and migs:
        ctx.warn(
            "project %s: falling back to per-MIG autoscaler fields; a MIG whose autoscaler "
            "is not reported inline could be evaluated as fixed size" % project
        )
    template_cache = {}
    rows = []

    for mig in migs:
        name = mig.get("name", "")
        target_size = int(mig.get("targetSize") or 0)
        regional = bool(mig.get("region")) and not mig.get("zone")
        location = last_segment(mig.get("zone") or mig.get("region") or "")

        if mig_is_autoscaled(mig, autoscaled):
            continue
        if target_size <= floor_size:
            continue
        if not ctx.older_than_threshold(mig.get("creationTimestamp")):
            continue

        try:
            stable = size_is_stable(ctx, project, name, location)
        except (MetricUnavailable, MetricHttpError) as exc:
            ctx.warn("project %s: mig %s: %s" % (project, name, exc))
            continue
        if stable is None:
            ctx.warn(
                "project %s: mig %s: no instance_group/size history; cannot confirm the "
                "target size held steady" % (project, name)
            )
            continue
        if not stable:
            continue

        instance_ids = member_instance_ids(ctx, project, name, location, regional)
        if not instance_ids:
            continue

        try:
            cpu_pct = peak_cpu(ctx, project, instance_ids)
        except (MetricUnavailable, MetricHttpError) as exc:
            ctx.warn("project %s: mig %s: %s" % (project, name, exc))
            continue
        if cpu_pct is None:
            ctx.warn(
                "project %s: mig %s: no CPU utilization series for its instances"
                % (project, name)
            )
            continue

        if cpu_pct >= threshold:
            continue

        recommended = int(math.ceil(target_size * cpu_pct / target_utilization))
        recommended = max(floor_size, recommended)
        if recommended >= target_size:
            continue

        machine_type = template_machine_type(ctx, project, mig.get("instanceTemplate"), template_cache)
        savings = None
        if ctx.pricing.enabled:
            per_instance = ctx.pricing.monthly("machine_type", machine_type)
            if per_instance is None:
                ctx.warn(
                    "project %s: mig %s: no pricing rate for machine type %s"
                    % (project, name, machine_type or "unknown")
                )
            else:
                savings = per_instance * (target_size - recommended)

        rows.append(
            ctx.row(
                project=project,
                name=name,
                region=location,
                description=(
                    "Peak CPU utilization is %s over the last %d days. Autoscaling disabled. "
                    "Target size remained fixed at %d instances for %d days. Machine type %s."
                    % (
                        pct(cpu_pct),
                        ctx.days,
                        target_size,
                        ctx.days,
                        machine_type or "unknown",
                    )
                ),
                action="Reduce target size from %d to %d" % (target_size, recommended),
                savings=savings,
            )
        )
    return rows


raise SystemExit(
    run_detection(
        "Overprovisioned Managed Instance Groups",
        detect,
        add_arguments=add_arguments,
    )
)
PYTHON

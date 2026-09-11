#!/usr/bin/env bash
# Recommendation : Overprovisioned App Engine (Overprovisioned)
# Source doc     : GCP Overprovisioned __ AppEngine.md
#
# Detection logic:
#   1. List App Engine services and versions in each target project.
#   2. Describe each version; keep only versions that use manual scaling.
#   3. Skip instance class B8 (no recommendation is defined for it).
#   4. Max appengine.googleapis.com/system/cpu/utilization and max
#      system/memory/usage over the lookback window, daily buckets,
#      ALIGN_MAX + REDUCE_MAX, filtered by resource label version_id.
#      Memory bytes are converted to a percentage of the instance class limit.
#   5. CPU < THRESHOLD and memory < THRESHOLD -> switch to automatic scaling and
#      downgrade one instance-class tier.
#      Otherwise -> switch to automatic scaling on the equivalent class.
#
# Usage: validate_overprovisioned_appengine.sh (-p PROJECTS | -o ORG_ID | -f FOLDER_ID) [options]
#
# Options:
#   -p PROJECTS     evaluate one project, or several as a comma-separated list
#   -o ORG_ID       evaluate every ACTIVE project under an organization
#   -f FOLDER_ID    evaluate every ACTIVE project under a folder
#   -d DAYS         lookback window in days (default 30)
#   -u THRESHOLD    utilization threshold percent (default 30)
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
import os
import sys

sys.path.insert(0, os.environ["GCP_RECO_LIB_DIR"])

from gcp_reco_lib import (
    NO_DATA,
    GcpError,
    MetricHttpError,
    MetricUnavailable,
    peak,
    pct,
    run_detection,
)

CPU = "appengine.googleapis.com/system/cpu/utilization"
MEMORY = "appengine.googleapis.com/system/memory/usage"

MIB = 1024.0 * 1024.0

# Instance class -> memory limit in MiB, and the next class down.
CLASS_MEMORY_MIB = {
    "B1": 384.0,
    "B2": 768.0,
    "B4": 1536.0,
    "B4_1G": 3072.0,
    "B8": 3072.0,
}
CLASS_DOWNGRADE = {
    "B2": "B1",
    "B4": "B2",
    "B4_1G": "B4",
    "B8": "B4_1G",
}


def add_arguments(parser):
    parser.add_argument("-u", dest="utilization", default="30")


def max_metric(ctx, project, metric, version_id):
    resource_filter = ' AND resource.labels.version_id="%s"' % version_id
    points = ctx.metrics.points(
        project,
        metric,
        resource_filter,
        aligner="ALIGN_MAX",
        alignment_period=86400,
        cross_series_reducer="REDUCE_MAX",
    )
    return None if points == NO_DATA else peak(points)


def detect(ctx, project):
    try:
        threshold = float(ctx.args.utilization)
    except (TypeError, ValueError):
        ctx.warn("THRESHOLD (-u) is not numeric; falling back to 30")
        threshold = 30.0

    try:
        app = ctx.gcloud.run(["app", "describe"], project=project)
    except GcpError as exc:
        if exc.kind in ("not_found", "api_disabled", "permission_denied"):
            ctx.warn("project %s: no App Engine application (%s)" % (project, exc.summary()))
            return []
        raise
    if not app:
        return []

    region = app.get("locationId", "")
    services = ctx.gcloud.run(["app", "services", "list"], project=project) or []
    rows = []

    for service in services:
        service_id = service.get("id") or service.get("name", "")
        if not service_id:
            continue
        versions = (
            ctx.gcloud.run(
                ["app", "versions", "list", "--service", service_id], project=project
            )
            or []
        )

        for entry in versions:
            version_id = entry.get("id") or entry.get("version", {}).get("id", "")
            if not version_id:
                continue

            try:
                detail = ctx.gcloud.run(
                    ["app", "versions", "describe", version_id, "--service", service_id],
                    project=project,
                )
            except GcpError as exc:
                ctx.warn(
                    "project %s: version %s: describe failed: %s"
                    % (project, version_id, exc.summary())
                )
                continue

            manual = (detail or {}).get("manualScaling")
            if not manual:
                continue

            instance_class = (detail or {}).get("instanceClass", "")
            if instance_class == "B8":
                continue

            try:
                cpu = max_metric(ctx, project, CPU, version_id)
                memory_bytes = max_metric(ctx, project, MEMORY, version_id)
            except (MetricUnavailable, MetricHttpError) as exc:
                ctx.warn("project %s: version %s: %s" % (project, version_id, exc))
                continue

            if cpu is None or memory_bytes is None:
                ctx.warn(
                    "project %s: version %s: no CPU or memory time series"
                    % (project, version_id)
                )
                continue

            cpu_pct = cpu * 100.0
            limit_mib = CLASS_MEMORY_MIB.get(instance_class)
            if limit_mib is None:
                ctx.warn(
                    "project %s: version %s: unknown instance class %s"
                    % (project, version_id, instance_class or "unset")
                )
                continue
            memory_pct = (memory_bytes / MIB) / limit_mib * 100.0

            instances = int(manual.get("instances") or 0)

            if cpu_pct < threshold and memory_pct < threshold:
                target = CLASS_DOWNGRADE.get(instance_class)
                if target is None:
                    continue
                description = (
                    "Maximum CPU utilization of version is %s and Memory utilization is %s. "
                    "The App Engine version has been identified as overprovisioned under "
                    "manual scaling with %d fixed instance(s)."
                    % (pct(cpu_pct), pct(memory_pct), instances)
                )
                action = "Switch to automatic scaling and downgrade instance class from %s to %s" % (
                    instance_class,
                    target,
                )
                savings = ctx.pricing.delta(
                    "appengine_instance_class", instance_class, target
                )
            else:
                description = (
                    "The App Engine version is configured to run on manual scaling with %d "
                    "fixed instance(s). Maximum CPU utilization is %s and Memory utilization "
                    "is %s." % (instances, pct(cpu_pct), pct(memory_pct))
                )
                action = "Switch to automatic scaling"
                savings = None

            if ctx.pricing.enabled and savings is None:
                ctx.warn(
                    "project %s: version %s: no pricing rate for instance class %s"
                    % (project, version_id, instance_class)
                )

            rows.append(
                ctx.row(
                    project=project,
                    name=version_id,
                    region=region,
                    description=description,
                    action=action,
                    kind="appengine-version",
                    link_name="%s (%s)" % (version_id, service_id),
                    savings=savings,
                )
            )
    return rows


raise SystemExit(
    run_detection(
        "Overprovisioned App Engine", detect, add_arguments=add_arguments
    )
)
PYTHON

#!/usr/bin/env bash
# Recommendation : VM Instance Overprovisioned (Overprovisioned)
# Source doc     : Overprovisioned __ GCP VM Instance.md
#
# Detection logic:
#   1. List Compute Engine instances; keep only RUNNING, non-Spot instances.
#   2. Max compute.googleapis.com/instance/cpu/utilization over the lookback
#      window, ALIGN_MAX at 300s, filtered by resource label instance_id.
#   3. Max agent.googleapis.com/memory/percent_used the same way, restricted to
#      metric.labels.state="used" (percent_used also reports free/buffered/
#      cached/slab_reclaimable states that sum to 100% with "used" -- without
#      this filter ALIGN_MAX silently mixes unrelated states together). This
#      needs the Ops Agent; when the series is absent the memory side is
#      reported unknown and only the CPU rule is applied.
#   4. CPU < THRESHOLD, memory >= THRESHOLD -> halve vCPU, keep memory.
#      CPU >= THRESHOLD, memory < THRESHOLD -> keep vCPU, size memory so the
#        observed peak lands at 60% utilization.
#      Both < THRESHOLD -> halve vCPU and apply the 60% memory target.
#   5. Pick the smallest predefined machine type in the SAME family that meets
#      both targets. Fall back to a custom type only for families that support
#      one (N1, N2, N2D, E2, N4, N4D, N4A) and only inside that family's
#      memory-per-vCPU band. Architecture, category and OS are unchanged because
#      the candidate never leaves the family.
#
# Usage: validate_overprovisioned_vm_instances.sh (-p PROJECTS | -o ORG_ID | -f FOLDER_ID) [options]
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
MEMORY = "agent.googleapis.com/memory/percent_used"

# percent_used reports mutually exclusive states (used, free, buffered, cached,
# slab_reclaimable, ...) that sum to 100%. Only "used" represents actual
# in-use memory; the others must not be folded into the same ALIGN_MAX.
MEMORY_STATE_USED_FILTER = ' AND metric.labels.state="used"'

TARGET_UTILIZATION = 0.60

# Families that accept custom machine types, with GB of memory per vCPU bounds.
CUSTOM_FAMILIES = {
    "n1": (0.9, 6.5),
    "n2": (0.5, 8.0),
    "n2d": (0.5, 8.0),
    "e2": (0.5, 8.0),
    "n4": (2.0, 8.0),
    "n4d": (2.0, 8.0),
    "n4a": (2.0, 8.0),
}
CUSTOM_CPU_RANGE = {
    "n1": (1, 96),
    "n2": (2, 80),
    "n2d": (2, 96),
    "e2": (2, 32),
    "n4": (2, 80),
    "n4d": (2, 96),
    "n4a": (1, 64),
}


def add_arguments(parser):
    parser.add_argument("-u", dest="utilization", default="30")


def family_of(machine_type):
    return machine_type.split("-", 1)[0].lower() if machine_type else ""


def is_spot(instance):
    scheduling = instance.get("scheduling") or {}
    if scheduling.get("preemptible"):
        return True
    return str(scheduling.get("provisioningModel", "")).upper() == "SPOT"


def max_metric(ctx, project, metric, instance_id, extra_filter=""):
    """Max aligned value of `metric` for `instance_id`.

    `extra_filter` lets callers narrow to a specific metric label (e.g. the
    memory metric's state="used" label) without baking metric-specific
    assumptions into this shared helper.
    """
    resource_filter = (
        ' AND resource.type="gce_instance" AND resource.labels.instance_id="%s"%s'
        % (instance_id, extra_filter)
    )
    points = ctx.metrics.points(
        project, metric, resource_filter, aligner="ALIGN_MAX", alignment_period=300
    )
    return None if points == NO_DATA else peak(points)


def machine_types(ctx, project, zone, cache):
    """Predefined machine types available in a zone, keyed by name."""
    if zone in cache:
        return cache[zone]
    catalogue = {}
    try:
        listed = (
            ctx.gcloud.run(
                ["compute", "machine-types", "list", "--filter", "zone:(%s)" % zone],
                project=project,
            )
            or []
        )
    except GcpError as exc:
        ctx.warn("project %s: zone %s: machine type list failed: %s" % (project, zone, exc.summary()))
        listed = []
    for entry in listed:
        name = entry.get("name", "")
        if not name or "custom" in name:
            continue
        catalogue[name] = (
            int(entry.get("guestCpus") or 0),
            float(entry.get("memoryMb") or 0),
        )
    cache[zone] = catalogue
    return catalogue


def pick_predefined(catalogue, family, target_cpu, target_memory_mb, current_name):
    """Smallest same-family predefined type that satisfies both targets."""
    best = None
    for name, (cpus, memory_mb) in catalogue.items():
        if family_of(name) != family or name == current_name:
            continue
        if cpus < target_cpu or memory_mb < target_memory_mb:
            continue
        key = (cpus, memory_mb)
        if best is None or key < best[1]:
            best = (name, key)
    return best[0] if best else None


def build_custom(family, target_cpu, target_memory_mb):
    """Custom machine type inside the family's documented bands, or None."""
    if family not in CUSTOM_FAMILIES:
        return None
    low_gb, high_gb = CUSTOM_FAMILIES[family]
    min_cpu, max_cpu = CUSTOM_CPU_RANGE[family]

    cpus = max(min_cpu, int(target_cpu))
    if cpus > 1 and cpus % 2 == 1:
        cpus += 1
    if cpus > max_cpu:
        return None

    # Custom memory must be a multiple of 256 MB and inside the per-vCPU band.
    memory_mb = int(math.ceil(target_memory_mb / 256.0) * 256)
    lower = int(math.ceil(cpus * low_gb * 1024))
    upper = int(cpus * high_gb * 1024)
    memory_mb = max(memory_mb, lower)
    if memory_mb > upper:
        return None
    memory_mb = int(math.ceil(memory_mb / 256.0) * 256)

    prefix = "custom" if family == "n1" else "%s-custom" % family
    return "%s-%d-%d" % (prefix, cpus, memory_mb)


def detect(ctx, project):
    try:
        threshold = float(ctx.args.utilization)
    except (TypeError, ValueError):
        ctx.warn("THRESHOLD (-u) is not numeric; falling back to 30")
        threshold = 30.0

    instances = ctx.gcloud.run(["compute", "instances", "list"], project=project) or []
    zone_cache = {}
    rows = []

    for instance in instances:
        name = instance.get("name", "")
        if instance.get("status") != "RUNNING":
            continue
        if is_spot(instance):
            continue

        instance_id = str(instance.get("id", ""))
        zone = last_segment(instance.get("zone", ""))
        machine_type = last_segment(instance.get("machineType", ""))
        family = family_of(machine_type)

        try:
            cpu = max_metric(ctx, project, CPU, instance_id)
            memory = max_metric(
                ctx, project, MEMORY, instance_id,
                extra_filter=MEMORY_STATE_USED_FILTER,
            )
        except (MetricUnavailable, MetricHttpError) as exc:
            ctx.warn("project %s: instance %s: %s" % (project, name, exc))
            continue

        if cpu is None:
            ctx.warn(
                "project %s: instance %s: no CPU utilization time series" % (project, name)
            )
            continue
        cpu_pct = cpu * 100.0
        memory_pct = memory  # already a percentage
        if memory_pct is None:
            ctx.warn(
                "project %s: instance %s: no Ops Agent memory series; CPU-only evaluation"
                % (project, name)
            )

        catalogue = machine_types(ctx, project, zone, zone_cache)
        current = catalogue.get(machine_type)
        if current is None:
            ctx.warn(
                "project %s: instance %s: machine type %s not in the zone catalogue"
                % (project, name, machine_type or "unset")
            )
            continue
        current_cpu, current_memory_mb = current

        cpu_low = cpu_pct < threshold
        memory_low = memory_pct is not None and memory_pct < threshold

        if not cpu_low and not memory_low:
            continue

        target_cpu = max(1, current_cpu // 2) if cpu_low else current_cpu
        if memory_low:
            used_mb = (memory_pct / 100.0) * current_memory_mb
            target_memory_mb = used_mb / TARGET_UTILIZATION
        else:
            target_memory_mb = current_memory_mb

        recommended = pick_predefined(
            catalogue, family, target_cpu, target_memory_mb, machine_type
        )
        if recommended is None:
            recommended = build_custom(family, target_cpu, target_memory_mb)
        if recommended is None:
            ctx.warn(
                "project %s: instance %s: no smaller %s configuration fits the targets"
                % (project, name, family or "unknown family")
            )
            continue
        if recommended == machine_type:
            continue

        if cpu_low and memory_low:
            description = (
                "Maximum CPU Utilization of VM is %s. Maximum Memory Utilization of VM is %s. "
                "The VM has been overprovisioned for the last %d+ days."
                % (pct(cpu_pct), pct(memory_pct), ctx.days)
            )
        elif cpu_low:
            description = (
                "Maximum CPU utilisation of VM is %s. The VM has been overprovisioned for the "
                "last %d+ days." % (pct(cpu_pct), ctx.days)
            )
        else:
            description = (
                "Maximum Memory Utilization of VM is %s. The VM has been overprovisioned for "
                "the last %d+ days." % (pct(memory_pct), ctx.days)
            )

        savings = ctx.pricing.delta("machine_type", machine_type, recommended)
        if ctx.pricing.enabled and savings is None:
            ctx.warn(
                "project %s: instance %s: no pricing rate for %s or %s"
                % (project, name, machine_type, recommended)
            )

        rows.append(
            ctx.row(
                project=project,
                name=name,
                region=zone,
                description=description,
                action="Downsize VM instance type from %s to %s" % (machine_type, recommended),
                kind="instance",
                savings=savings,
            )
        )
    return rows


raise SystemExit(
    run_detection(
        "Overprovisioned VM Instances", detect, add_arguments=add_arguments
    )
)
PYTHON

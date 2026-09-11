#!/usr/bin/env bash
# Recommendation : Overprovisioned Cloud Run (Overprovisioned)
# Source doc     : CloudRun Overprovisioned.md
#
# Detection logic:
#   1. List Cloud Run services and describe each one.
#   2. Evaluate only instance-based billing with manual scaling, i.e. CPU always
#      allocated (run.googleapis.com/cpu-throttling = false) and manual scaling
#      configured. Request-based and instance-based-auto services are skipped:
#      downsizing an autoscaled service can trip its utilization target.
#   3. Max run.googleapis.com/container/cpu/utilizations and
#      container/memory/utilizations over the lookback window. These are
#      DISTRIBUTION metrics, so the per-point maximum is used and scaled to a
#      percentage.
#   4. CPU < THRESHOLD and memory < THRESHOLD -> downsize vCPU and memory.
#      CPU >= THRESHOLD and memory < THRESHOLD -> downsize memory only.
#      Low CPU with high memory yields no recommendation, per the source doc.
#   5. The target pair is the next smaller vCPU/memory combination that stays
#      inside the documented Cloud Run vCPU-to-memory bands.
#
# Usage: validate_overprovisioned_cloud_run.sh (-p PROJECTS | -o ORG_ID | -f FOLDER_ID) [options]
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
    MetricHttpError,
    MetricUnavailable,
    peak,
    pct,
    run_detection,
)

CPU = "run.googleapis.com/container/cpu/utilizations"
MEMORY = "run.googleapis.com/container/memory/utilizations"

# vCPU -> (min MiB, max MiB) allowed by Cloud Run.
CPU_MEMORY_BANDS = [
    (1.0, 128.0, 4096.0),
    (2.0, 128.0, 8192.0),
    (4.0, 2048.0, 16384.0),
    (6.0, 4096.0, 24576.0),
    (8.0, 4096.0, 32768.0),
]

MIB = 1024.0 * 1024.0


def add_arguments(parser):
    parser.add_argument("-u", dest="utilization", default="30")


def parse_quantity(value, default=0.0):
    """Parse a Kubernetes-style CPU or memory quantity."""
    if not value:
        return default
    text = str(value).strip()
    units = {
        "m": 0.001,
        "Ki": 1024.0 / MIB,
        "Mi": 1.0,
        "Gi": 1024.0,
        "M": 1000000.0 / MIB,
        "G": 1000000000.0 / MIB,
        "k": 1000.0 / MIB,
    }
    for suffix in ("Ki", "Mi", "Gi", "m", "M", "G", "k"):
        if text.endswith(suffix):
            try:
                return float(text[: -len(suffix)]) * units[suffix]
            except ValueError:
                return default
    try:
        return float(text)
    except ValueError:
        return default


def container_limits(service):
    template = ((service.get("spec") or {}).get("template") or {})
    containers = ((template.get("spec") or {}).get("containers") or [])
    if not containers:
        return (0.0, 0.0)
    limits = (containers[0].get("resources") or {}).get("limits") or {}
    vcpu = parse_quantity(limits.get("cpu"), 0.0)
    memory_mib = parse_quantity(limits.get("memory"), 0.0)
    return (vcpu, memory_mib)


def is_instance_based_manual(service):
    """Instance-based billing with manual scaling."""
    metadata = service.get("metadata") or {}
    annotations = dict(metadata.get("annotations") or {})
    template = ((service.get("spec") or {}).get("template") or {})
    annotations.update((template.get("metadata") or {}).get("annotations") or {})

    # CPU always allocated == instance-based billing.
    throttling = str(annotations.get("run.googleapis.com/cpu-throttling", "true")).lower()
    always_allocated = throttling == "false"

    scaling_mode = str(annotations.get("run.googleapis.com/scalingMode", "")).lower()
    manual = scaling_mode == "manual" or "run.googleapis.com/manualInstanceCount" in annotations

    return always_allocated and manual


def band_for(vcpu):
    for cpus, low, high in CPU_MEMORY_BANDS:
        if vcpu <= cpus:
            return (cpus, low, high)
    return CPU_MEMORY_BANDS[-1]


def smaller_cpu(vcpu):
    candidates = [cpus for cpus, _, _ in CPU_MEMORY_BANDS if cpus < vcpu]
    return max(candidates) if candidates else None


def halve_memory(memory_mib, vcpu):
    """Halve memory, clamped to the band minimum for the given vCPU count."""
    _, low, high = band_for(vcpu)
    target = max(low, memory_mib / 2.0)
    target = min(target, high)
    return target if target < memory_mib else None


def render_memory(memory_mib):
    if memory_mib >= 1024.0 and math.isclose(memory_mib % 1024.0, 0.0, abs_tol=0.01):
        return "%dGi" % int(memory_mib / 1024.0)
    return "%dMi" % int(round(memory_mib))


def render_cpu(vcpu):
    return "%g" % vcpu


def max_utilization_pct(ctx, project, metric, service_name, region):
    resource_filter = (
        ' AND resource.labels.service_name="%s" AND resource.labels.location="%s"'
        % (service_name, region)
    )
    points = ctx.metrics.points(
        project,
        metric,
        resource_filter,
        aligner="ALIGN_MAX",
        alignment_period=86400,
        cross_series_reducer="REDUCE_MAX",
    )
    if points == NO_DATA:
        return None
    return peak(points) * 100.0


def detect(ctx, project):
    try:
        threshold = float(ctx.args.utilization)
    except (TypeError, ValueError):
        ctx.warn("THRESHOLD (-u) is not numeric; falling back to 30")
        threshold = 30.0

    services = (
        ctx.gcloud.run(["run", "services", "list", "--platform", "managed"], project=project)
        or []
    )
    rows = []

    for service in services:
        metadata = service.get("metadata") or {}
        name = metadata.get("name", "")
        region = (metadata.get("labels") or {}).get("cloud.googleapis.com/location", "")

        if not is_instance_based_manual(service):
            continue

        vcpu, memory_mib = container_limits(service)
        if vcpu <= 0 or memory_mib <= 0:
            ctx.warn("project %s: service %s: no CPU/memory limits declared" % (project, name))
            continue

        try:
            cpu_pct = max_utilization_pct(ctx, project, CPU, name, region)
            memory_pct = max_utilization_pct(ctx, project, MEMORY, name, region)
        except (MetricUnavailable, MetricHttpError) as exc:
            ctx.warn("project %s: service %s: %s" % (project, name, exc))
            continue

        if cpu_pct is None or memory_pct is None:
            ctx.warn(
                "project %s: service %s: no CPU or memory utilization time series"
                % (project, name)
            )
            continue

        if memory_pct >= threshold:
            # High memory: neither documented case applies.
            continue

        new_memory = halve_memory(memory_mib, vcpu)

        if cpu_pct < threshold:
            new_cpu = smaller_cpu(vcpu)
            if new_cpu is None and new_memory is None:
                continue
            target_cpu = new_cpu if new_cpu is not None else vcpu
            target_memory = halve_memory(memory_mib, target_cpu) or memory_mib
            if target_cpu == vcpu and target_memory == memory_mib:
                continue
            description = (
                "CPU and Memory are Over Provisioned. Maximum CPU utilisation is %s. "
                "Maximum Memory utilisation is %s. For the last %d+ days."
                % (pct(cpu_pct), pct(memory_pct), ctx.days)
            )
            action = (
                "Downsize the container from %s vCPU / %s to %s vCPU / %s"
                % (
                    render_cpu(vcpu),
                    render_memory(memory_mib),
                    render_cpu(target_cpu),
                    render_memory(target_memory),
                )
            )
        else:
            if new_memory is None:
                continue
            target_cpu = vcpu
            target_memory = new_memory
            description = (
                "Memory is Over Provisioned. Maximum Memory utilisation is %s. "
                "For the last %d+ days." % (pct(memory_pct), ctx.days)
            )
            action = "Downsize the container's Memory from %s to %s (keep CPU at %s vCPU)" % (
                render_memory(memory_mib),
                render_memory(target_memory),
                render_cpu(vcpu),
            )

        savings = ctx.pricing.delta(
            "cloud_run_cpu", "vcpu", "vcpu", vcpu, target_cpu
        )
        if savings is not None:
            memory_saving = ctx.pricing.delta(
                "cloud_run_memory",
                "gib",
                "gib",
                memory_mib / 1024.0,
                target_memory / 1024.0,
            )
            savings += memory_saving or 0.0

        rows.append(
            ctx.row(
                project=project,
                name=name,
                region=region,
                description=description,
                action=action,
                kind="run",
                savings=savings,
            )
        )
    return rows


raise SystemExit(
    run_detection(
        "Overprovisioned Cloud Run", detect, add_arguments=add_arguments
    )
)
PYTHON

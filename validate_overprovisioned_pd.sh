#!/usr/bin/env bash
# Recommendation : Persistent Disk Overprovisioned (Overprovisioned)
# Source doc     : OverProvisioned _ PD.md
#
# Detection logic:
#   1. List disks and keep those that actually carry provisioned performance
#      (provisionedIops and/or provisionedThroughput): pd-extreme and the
#      hyperdisk family. Disk types without configurable performance are skipped.
#   2. Sum read_ops_count + write_ops_count and read_bytes_count +
#      write_bytes_count per disk over the lookback window, aligned as a
#      per-minute rate, and take the peak.
#   3. iops_utilization = peak IOPS / provisioned IOPS.
#      throughput_utilization = peak throughput / provisioned throughput.
#   4. Both below THRESHOLD -> underutilized. Where a disk type only exposes one
#      of the two knobs, only that dimension gates the finding.
#   5. Target = peak / 0.60, clamped into the disk type's configurable range.
#      A disk already at the floor of its range yields no recommendation.
#
# Usage: validate_overprovisioned_pd.sh (-p PROJECTS | -o ORG_ID | -f FOLDER_ID) [options]
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
    last_segment,
    peak,
    pct,
    run_detection,
)

READ_OPS = "compute.googleapis.com/instance/disk/read_ops_count"
WRITE_OPS = "compute.googleapis.com/instance/disk/write_ops_count"
READ_BYTES = "compute.googleapis.com/instance/disk/read_bytes_count"
WRITE_BYTES = "compute.googleapis.com/instance/disk/write_bytes_count"

TARGET_UTILIZATION = 0.60
MIB = 1024.0 * 1024.0

# Disk types whose performance is configurable, and which knobs they expose.
CONFIGURABLE = {
    "pd-extreme": ("iops",),
    "hyperdisk-balanced": ("iops", "throughput"),
    "hyperdisk-balanced-high-availability": ("iops", "throughput"),
    "hyperdisk-extreme": ("iops",),
    "hyperdisk-ml": ("throughput",),
    "hyperdisk-throughput": ("throughput",),
}


def add_arguments(parser):
    parser.add_argument("-u", dest="utilization", default="30")


def iops_range(disk_type, size_gib):
    """(min, max) provisionable IOPS for a disk type and size."""
    if disk_type == "pd-extreme":
        return (2500.0, 120000.0)
    if disk_type in ("hyperdisk-balanced", "hyperdisk-balanced-high-availability"):
        ceiling = 100000.0 if "high-availability" in disk_type else 160000.0
        if size_gib <= 4:
            return (2000.0, 2000.0)
        if size_gib <= 5:
            return (2500.0, 2500.0)
        return (3000.0, min(500.0 * size_gib, ceiling))
    if disk_type == "hyperdisk-extreme":
        upper = 350000.0 if size_gib >= 292 else 1200.0 * size_gib
        return (2.0 * size_gib, upper)
    return (None, None)


def throughput_range(disk_type, size_gib, provisioned_iops):
    """(min, max) provisionable throughput in MiB/s."""
    if disk_type in ("hyperdisk-balanced", "hyperdisk-balanced-high-availability"):
        cap = 1200.0 if "high-availability" in disk_type else 2400.0
        if size_gib <= 5:
            return (140.0, 140.0)
        if not provisioned_iops:
            return (140.0, cap)
        return (max(140.0, provisioned_iops / 256.0), min(cap, provisioned_iops / 4.0))
    if disk_type == "hyperdisk-ml":
        return (max(400.0, 0.12 * size_gib), min(1200000.0, 1600.0 * size_gib))
    if disk_type == "hyperdisk-throughput":
        size_tib = size_gib / 1024.0
        return (10.0 * size_tib, min(90.0 * size_tib, 2400.0))
    return (None, None)


def rate_peak(ctx, project, metric, disk_name):
    """Peak per-second rate for a disk metric, or None when unavailable."""
    resource_filter = ' AND metric.labels.device_name="%s"' % disk_name
    points = ctx.metrics.points(
        project, metric, resource_filter, aligner="ALIGN_RATE", alignment_period=60
    )
    return None if points == NO_DATA else peak(points)


def detect(ctx, project):
    try:
        threshold = float(ctx.args.utilization)
    except (TypeError, ValueError):
        ctx.warn("THRESHOLD (-u) is not numeric; falling back to 30")
        threshold = 30.0

    disks = ctx.gcloud.run(["compute", "disks", "list"], project=project) or []
    rows = []

    for disk in disks:
        name = disk.get("name", "")
        disk_type = last_segment(disk.get("type", ""))
        knobs = CONFIGURABLE.get(disk_type)
        if not knobs:
            continue

        size_gib = float(disk.get("sizeGb") or 0)
        provisioned_iops = float(disk.get("provisionedIops") or 0)
        provisioned_throughput = float(disk.get("provisionedThroughput") or 0)
        location = last_segment(disk.get("zone") or disk.get("region") or "")

        try:
            read_ops = rate_peak(ctx, project, READ_OPS, name)
            write_ops = rate_peak(ctx, project, WRITE_OPS, name)
            read_bytes = rate_peak(ctx, project, READ_BYTES, name)
            write_bytes = rate_peak(ctx, project, WRITE_BYTES, name)
        except (MetricUnavailable, MetricHttpError) as exc:
            ctx.warn("project %s: disk %s: %s" % (project, name, exc))
            continue

        if read_ops is None and write_ops is None and read_bytes is None and write_bytes is None:
            ctx.warn("project %s: disk %s: no disk performance time series" % (project, name))
            continue

        peak_iops = (read_ops or 0.0) + (write_ops or 0.0)
        peak_throughput = ((read_bytes or 0.0) + (write_bytes or 0.0)) / MIB

        iops_util = (peak_iops / provisioned_iops * 100.0) if provisioned_iops else None
        throughput_util = (
            (peak_throughput / provisioned_throughput * 100.0)
            if provisioned_throughput
            else None
        )

        checks = []
        if "iops" in knobs and iops_util is not None:
            checks.append(iops_util)
        if "throughput" in knobs and throughput_util is not None:
            checks.append(throughput_util)
        if not checks or any(value >= threshold for value in checks):
            continue

        actions = []
        details = []
        savings = 0.0 if ctx.pricing.enabled else None

        if "iops" in knobs and provisioned_iops:
            low, high = iops_range(disk_type, size_gib)
            target = peak_iops / TARGET_UTILIZATION
            if low is not None:
                target = max(low, min(target, high))
                target = math.ceil(target)
                if target < provisioned_iops:
                    actions.append("Change IOPS: %d to %d" % (int(provisioned_iops), target))
                    if savings is not None:
                        delta = ctx.pricing.delta(
                            "disk_iops", disk_type, disk_type, provisioned_iops, target
                        )
                        savings = None if delta is None else savings + delta
            details.append("IOPS utilization %s of %d provisioned" % (pct(iops_util), int(provisioned_iops)))

        if "throughput" in knobs and provisioned_throughput:
            low, high = throughput_range(disk_type, size_gib, provisioned_iops)
            target = peak_throughput / TARGET_UTILIZATION
            if low is not None:
                target = max(low, min(target, high))
                target = math.ceil(target)
                if target < provisioned_throughput:
                    actions.append(
                        "Change throughput: %d to %d MiB/s"
                        % (int(provisioned_throughput), target)
                    )
                    if savings is not None:
                        delta = ctx.pricing.delta(
                            "disk_throughput",
                            disk_type,
                            disk_type,
                            provisioned_throughput,
                            target,
                        )
                        savings = None if delta is None else savings + delta
            details.append(
                "throughput utilization %s of %d MiB/s provisioned"
                % (pct(throughput_util), int(provisioned_throughput))
            )

        if not actions:
            # Already at the floor of its configurable range.
            continue

        rows.append(
            ctx.row(
                project=project,
                name=name,
                region=location,
                description=(
                    "The current %s disk is underutilized: %s over the last %d days."
                    % (disk_type, ", ".join(details), ctx.days)
                ),
                action=". ".join(actions) + ".",
                kind="disk" if disk.get("zone") else "regional-disk",
                savings=savings,
            )
        )
    return rows


raise SystemExit(
    run_detection(
        "Overprovisioned Persistent Disks", detect, add_arguments=add_arguments
    )
)
PYTHON

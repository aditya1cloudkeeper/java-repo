#!/usr/bin/env bash
# Recommendation : Overprovisioned Filestore (Overprovisioned)
# Source doc     : OverProvisioned _ FileStore.md
#
# Detection logic:
#   1. List and describe every Filestore instance; skip BASIC_HDD and BASIC_SSD
#      (no performance adjustment available).
#   2. Max over the lookback window of used_bytes_percent, read_ops_count,
#      write_ops_count, read_bytes_count and write_bytes_count.
#   3. All four performance metrics must sit at or below THRESHOLD of the
#      provisioned figures before anything is recommended.
#   4. Then, per the source doc:
#        ENTERPRISE, or ZONAL/REGIONAL without custom performance, and used space
#          <= THRESHOLD              -> Case 1, reduce capacity only
#        ZONAL/REGIONAL with custom performance and used space > THRESHOLD
#                                    -> Case 2, reduce IOPS only
#        custom performance and used space <= THRESHOLD
#                                    -> Case 3, reduce both
#   5. Capacity target halves current capacity with a 1 TiB floor, rounded up to
#      the 0.25 TiB or 2.5 TiB step for the band. IOPS target halves provisioned
#      read IOPS and is only emitted when it lands inside the band's performance
#      range. Capacity is never changed when current capacity is 1 TiB.
#
# Usage: validate_overprovisioned_filestore.sh (-p PROJECTS | -o ORG_ID | -f FOLDER_ID) [options]
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

USED_PERCENT = "file.googleapis.com/nfs/server/used_bytes_percent"
READ_OPS = "file.googleapis.com/nfs/server/read_ops_count"
WRITE_OPS = "file.googleapis.com/nfs/server/write_ops_count"
READ_BYTES = "file.googleapis.com/nfs/server/read_bytes_count"
WRITE_BYTES = "file.googleapis.com/nfs/server/write_bytes_count"

BASIC_TIERS = {"BASIC_HDD", "BASIC_SSD", "STANDARD", "PREMIUM"}
MIB = 1024.0 * 1024.0


def add_arguments(parser):
    parser.add_argument("-u", dest="utilization", default="30")


def metric_max(ctx, project, metric, instance_name, location):
    resource_filter = (
        ' AND resource.labels.instance_name="%s" AND resource.labels.location="%s"'
        % (instance_name, location)
    )
    points = ctx.metrics.points(
        project, metric, resource_filter, aligner="ALIGN_MAX", alignment_period=86400
    )
    return None if points == NO_DATA else peak(points)


def capacity_tib(instance):
    for share in instance.get("fileShares") or []:
        capacity = share.get("capacityGb")
        if capacity:
            return float(capacity) / 1024.0
    return 0.0


def round_step(value, step):
    return math.ceil(value / step) * step


def recommended_capacity(current_tib, tier, custom_perf):
    """Halve capacity with a 1 TiB floor, rounded to the band's step."""
    if current_tib <= 1.0:
        return None
    expected = max(1.0, current_tib / 2.0)
    if tier == "ENTERPRISE":
        target = round_step(expected, 0.25)
    elif 1.0 <= expected <= 9.75:
        target = round_step(expected, 0.25)
    else:
        target = round_step(expected, 2.5)
    return target if target < current_tib else None


def performance_range(capacity_tib_value):
    """Allowed provisioned IOPS range for a capacity band."""
    if 1.0 <= capacity_tib_value <= 9.75:
        return (
            round_step(4000.0 * capacity_tib_value / 1000.0, 1) * 1000.0,
            round_step(17000.0 * capacity_tib_value / 1000.0, 1) * 1000.0,
        )
    return (
        round_step(3000.0 * capacity_tib_value / 1000.0, 1) * 1000.0,
        round_step(7500.0 * capacity_tib_value / 1000.0, 1) * 1000.0,
    )


def detect(ctx, project):
    try:
        threshold = float(ctx.args.utilization)
    except (TypeError, ValueError):
        ctx.warn("THRESHOLD (-u) is not numeric; falling back to 30")
        threshold = 30.0

    instances = ctx.gcloud.run(["filestore", "instances", "list"], project=project) or []
    rows = []

    for instance in instances:
        parts = (instance.get("name") or "").split("/")
        short_name = parts[-1] if parts else ""
        location = parts[3] if len(parts) > 3 else (instance.get("locationId") or "")
        tier = (instance.get("tier") or "").upper()

        if tier in BASIC_TIERS:
            continue

        performance = instance.get("performanceConfig") or {}
        limits = instance.get("performanceLimits") or {}
        custom_perf = bool(performance.get("iopsPerTb") or performance.get("fixedIops"))

        provisioned_read_iops = float(limits.get("maxReadIops") or 0)
        provisioned_write_iops = float(limits.get("maxWriteIops") or 0)
        provisioned_read_tp = float(limits.get("maxReadThroughputBps") or 0) / MIB
        provisioned_write_tp = float(limits.get("maxWriteThroughputBps") or 0) / MIB

        if not provisioned_read_iops or not provisioned_write_iops:
            ctx.warn(
                "project %s: filestore %s: performance limits not reported by the API"
                % (project, short_name)
            )
            continue

        try:
            used_pct = metric_max(ctx, project, USED_PERCENT, short_name, location)
            read_ops = metric_max(ctx, project, READ_OPS, short_name, location)
            write_ops = metric_max(ctx, project, WRITE_OPS, short_name, location)
            read_bytes = metric_max(ctx, project, READ_BYTES, short_name, location)
            write_bytes = metric_max(ctx, project, WRITE_BYTES, short_name, location)
        except (MetricUnavailable, MetricHttpError) as exc:
            ctx.warn("project %s: filestore %s: %s" % (project, short_name, exc))
            continue

        if used_pct is None:
            ctx.warn(
                "project %s: filestore %s: no used_bytes_percent series"
                % (project, short_name)
            )
            continue

        read_ops = read_ops or 0.0
        write_ops = write_ops or 0.0
        read_tp = (read_bytes or 0.0) / MIB
        write_tp = (write_bytes or 0.0) / MIB

        limit = threshold / 100.0
        within = (
            read_ops <= limit * provisioned_read_iops
            and write_ops <= limit * provisioned_write_iops
            and (not provisioned_read_tp or read_tp <= limit * provisioned_read_tp)
            and (not provisioned_write_tp or write_tp <= limit * provisioned_write_tp)
        )
        if not within:
            continue

        current_tib = capacity_tib(instance)
        space_low = used_pct <= threshold

        actions = []
        if tier == "ENTERPRISE" or (not custom_perf):
            if not space_low:
                continue
            target = recommended_capacity(current_tib, tier, custom_perf)
            if target is None:
                continue
            actions.append(
                "Reduce the Capacity from %.2f TiB to %.2f TiB" % (current_tib, target)
            )
            new_capacity = target
        else:
            new_capacity = current_tib
            if space_low:
                target = recommended_capacity(current_tib, tier, custom_perf)
                if target is not None:
                    new_capacity = target
                    actions.append(
                        "Reduce the Capacity from %.2f TiB to %.2f TiB"
                        % (current_tib, target)
                    )
            low, high = performance_range(new_capacity)
            half_iops = provisioned_read_iops / 2.0
            if low <= half_iops <= high:
                actions.append(
                    "Reduce the IOPS from %d to %d"
                    % (int(provisioned_read_iops), int(half_iops))
                )
            if not actions:
                continue

        savings = None
        if ctx.pricing.enabled:
            savings = ctx.pricing.delta(
                "filestore", tier, tier, current_tib * 1024.0, new_capacity * 1024.0
            )
            if savings is None:
                ctx.warn(
                    "project %s: filestore %s: no pricing rate for tier %s"
                    % (project, short_name, tier)
                )

        rows.append(
            ctx.row(
                project=project,
                name=short_name,
                region=location,
                description=(
                    "Used Capacity is %s. Max Read IOPS used is %s of provisioned, max Write "
                    "IOPS used is %s of provisioned, over the last %d days."
                    % (
                        pct(used_pct),
                        pct(read_ops / provisioned_read_iops * 100.0),
                        pct(write_ops / provisioned_write_iops * 100.0),
                        ctx.days,
                    )
                ),
                action=". ".join(actions) + ".",
                kind="filestore",
                savings=savings,
            )
        )
    return rows


raise SystemExit(
    run_detection(
        "Overprovisioned Filestore", detect, add_arguments=add_arguments
    )
)
PYTHON

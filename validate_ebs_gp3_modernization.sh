#!/usr/bin/env bash
# Recommendation : EC2 EBS - volume type modernization (Modernization)
# Cloud          : AWS, Elastic Block Storage
# Finding reasons: MOVE_TO_GP3, PROVISIONED_IOPS_NOT_REQUIRED, MOVE_IO1_TO_IO2
#
# Detection logic:
#   1. Describe gp2, io1 and io2 volumes in every requested region.
#   2. gp3 baseline is 3000 IOPS and 125 MiB/s throughput.
#   3. Peak IOPS over the lookback window comes from CloudWatch AWS/EBS
#      VolumeReadOps and VolumeWriteOps. Each datapoint is a Sum of operations
#      over the period, so IOPS = Sum / period. Following the source doc,
#      maxIopsUsage = max(read IOPS) + max(write IOPS), which is the conservative
#      upper bound rather than the timestamp-aligned peak.
#   4. Cases:
#        gp2                                   -> MOVE_TO_GP3
#        io1/io2, multi-attach off, peak <= 3000
#                                              -> PROVISIONED_IOPS_NOT_REQUIRED
#        io1, peak > 3000                      -> MOVE_IO1_TO_IO2
#      io1/io2 volumes with Multi-Attach enabled are excluded from the gp3 move,
#      per Step 2 of the source doc. io2 already above baseline is left alone.
#
#   Two notes where this departs from the doc, both called out in the row text:
#   - The doc compares raw VolumeReadOps counts against 3000 IOPS. Those units do
#     not match (a count over an hour is not a rate), so this script converts to
#     IOPS by dividing by the period before comparing.
#   - Case 1 triggers on volume type alone, so a large gp2 volume whose observed
#     peak exceeds the gp3 baseline is still reported; the description says how
#     many IOPS must be provisioned on gp3 to hold performance.
#
# Usage: validate_ebs_gp3_modernization.sh [options]
#
# Options:
#   -r REGIONS      comma-separated regions (default: discover via describe-regions)
#   -d DAYS         CloudWatch lookback window in days (default 30)
#   -e PERIOD       CloudWatch period in seconds (default 3600)
#   -b BASELINE     gp3 baseline IOPS used for the comparison (default 3000)
#   -s STATES       comma-separated volume states to evaluate (default in-use)
#                   use "all" to include available volumes too
#   -A ACCOUNT_ID   override the account ID shown in the first column
#   -U PROFILE      aws CLI profile to use
#   -P PRICING_FILE pricing table (CSV or JSON) used for Potential Savings
#   -c CSV_FILE     also write the rows to CSV_FILE (overwrites)
#   -j              print a JSON array instead of the Markdown table
#   -v              echo each aws invocation to stderr
#   -h              print this header and exit
#
# Exit codes: 0 success, 1 argument or dependency failure, 2 every region failed
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

for arg in "$@"; do
  if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
    awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "${BASH_SOURCE[0]}"
    exit 0
  fi
done

command -v aws >/dev/null 2>&1 || { echo "aws CLI not found on PATH" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 not found on PATH" >&2; exit 1; }

AWS_RECO_LIB_DIR="$SCRIPT_DIR" exec python3 - "$@" <<'PYTHON'
import math
import os
import sys

sys.path.insert(0, os.environ["AWS_RECO_LIB_DIR"])

from aws_reco_lib import (
    NO_DATA,
    AwsError,
    peak,
    pct,
    run_detection,
)

NAMESPACE = "AWS/EBS"
READ_OPS = "VolumeReadOps"
WRITE_OPS = "VolumeWriteOps"

GP3_BASELINE_THROUGHPUT_MIBPS = 125

# gp2 delivers 3 IOPS per GiB, floored at 100 and capped at 16000.
GP2_IOPS_PER_GIB = 3
GP2_MIN_IOPS = 100
GP2_MAX_IOPS = 16000

TARGET_TYPES = ("gp2", "io1", "io2")


def add_arguments(parser):
    parser.add_argument("-e", dest="period", default="3600")
    parser.add_argument("-b", dest="baseline", default="3000")
    parser.add_argument("-s", dest="states", default="in-use")


def number(ctx, value, fallback, label):
    try:
        return float(value)
    except (TypeError, ValueError):
        ctx.warn("%s is not numeric; falling back to %s" % (label, fallback))
        return float(fallback)


def describe_volumes(ctx, region, states):
    """Every gp2/io1/io2 volume in the region.

    AWS CLI v2 auto-paginates, so this normally completes in one call; the loop
    is here in case pagination has been disabled in the caller's CLI config.
    """
    volumes = []
    next_token = None
    while True:
        args = [
            "ec2",
            "describe-volumes",
            "--filters",
            "Name=volume-type,Values=%s" % ",".join(TARGET_TYPES),
        ]
        if states:
            args += ["Name=status,Values=%s" % ",".join(states)]
        if next_token:
            args += ["--starting-token", next_token]
        payload = ctx.aws.run(args, region=region)
        volumes.extend((payload or {}).get("Volumes", []) or [])
        next_token = (payload or {}).get("NextToken")
        if not next_token:
            break
    return volumes


def gp2_baseline_iops(size_gib):
    return max(GP2_MIN_IOPS, min(GP2_IOPS_PER_GIB * int(size_gib), GP2_MAX_IOPS))


def max_iops(ctx, region, volume_id, period):
    """(max read IOPS, max write IOPS) or (None, None) when CloudWatch is silent."""
    results = []
    for metric in (READ_OPS, WRITE_OPS):
        datapoints = ctx.metrics.datapoints(
            region,
            NAMESPACE,
            metric,
            [("VolumeId", volume_id)],
            period=period,
            statistic="Sum",
        )
        if datapoints == NO_DATA:
            results.append(None)
            continue
        # Each Sum covers one period, so dividing converts a count into a rate.
        results.append(peak([(stamp, value / period) for stamp, value in datapoints]))
    return tuple(results)


def storage_cost(ctx, volume_type, size_gib):
    return ctx.pricing.monthly("ebs_storage", volume_type, size_gib)


def iops_cost(ctx, volume_type, provisioned_iops):
    if not provisioned_iops:
        return 0.0
    return ctx.pricing.monthly("ebs_iops", volume_type, provisioned_iops)


def gp3_cost(ctx, size_gib, extra_iops):
    base = storage_cost(ctx, "gp3", size_gib)
    if base is None:
        return None
    if extra_iops > 0:
        surcharge = ctx.pricing.monthly("ebs_iops", "gp3", extra_iops)
        if surcharge is None:
            return None
        base += surcharge
    return base


def detect(ctx, region):
    period = int(number(ctx, ctx.args.period, 3600, "PERIOD (-e)"))
    baseline = number(ctx, ctx.args.baseline, 3000, "BASELINE (-b)")
    states_arg = (ctx.args.states or "in-use").strip().lower()
    states = None if states_arg == "all" else [
        item.strip() for item in states_arg.split(",") if item.strip()
    ]

    volumes = describe_volumes(ctx, region, states)
    rows = []

    for volume in volumes:
        volume_id = volume.get("VolumeId", "")
        volume_type = (volume.get("VolumeType") or "").lower()
        size_gib = float(volume.get("Size") or 0)
        provisioned_iops = float(volume.get("Iops") or 0)
        multi_attach = bool(volume.get("MultiAttachEnabled"))
        state = volume.get("State", "")

        if volume_type not in TARGET_TYPES:
            continue

        try:
            read_iops, write_iops = max_iops(ctx, region, volume_id, period)
        except AwsError as exc:
            ctx.warn("region %s: volume %s: %s" % (region, volume_id, exc.summary()))
            continue

        measured = read_iops is not None or write_iops is not None
        # Doc formula: sum of the independent maxima, a conservative upper bound.
        peak_iops = (read_iops or 0.0) + (write_iops or 0.0)

        if volume_type == "gp2":
            current_baseline = gp2_baseline_iops(size_gib)
            extra_iops = 0.0
            if measured and peak_iops > baseline:
                extra_iops = math.ceil(peak_iops - baseline)

            notes = ["The EBS volume is currently using gp2 storage type"]
            notes.append(
                "gp2 baseline is %d IOPS at %d GiB" % (current_baseline, int(size_gib))
            )
            if not measured:
                notes.append(
                    "No CloudWatch VolumeReadOps/VolumeWriteOps data in the last %d days, "
                    "so observed IOPS could not be confirmed (state %s)" % (ctx.days, state)
                )
            elif extra_iops > 0:
                notes.append(
                    "Peak usage %d IOPS exceeds the gp3 baseline of %d, so provision "
                    "%d extra IOPS on gp3 to hold performance"
                    % (int(peak_iops), int(baseline), int(extra_iops))
                )
            else:
                notes.append(
                    "Peak usage %d IOPS fits within the gp3 baseline of %d"
                    % (int(peak_iops), int(baseline))
                )

            savings = None
            if ctx.pricing.enabled:
                now_cost = storage_cost(ctx, "gp2", size_gib)
                new_cost = gp3_cost(ctx, size_gib, extra_iops)
                if now_cost is None or new_cost is None:
                    ctx.warn(
                        "region %s: volume %s: no pricing rate for gp2 or gp3"
                        % (region, volume_id)
                    )
                else:
                    savings = max(0.0, now_cost - new_cost)

            rows.append(
                ctx.row(
                    resource_id=volume_id,
                    region=region,
                    description=". ".join(notes) + ".",
                    action="Move volume from gp2 to gp3",
                    kind="ebs-volume",
                    savings=savings,
                )
            )
            continue

        # io1 / io2 from here on.
        if not measured:
            ctx.warn(
                "region %s: volume %s: no CloudWatch IOPS data; cannot judge whether "
                "provisioned IOPS are required" % (region, volume_id)
            )
            continue

        utilization = (peak_iops / provisioned_iops * 100.0) if provisioned_iops else 0.0

        if peak_iops <= baseline:
            if multi_attach:
                # Excluded from the gp3 move by Step 2 of the source doc.
                continue
            notes = [
                "Provisioned IOPS not required",
                "Maximum IOPS utilization is %s for the last %d+ days"
                % (pct(utilization), ctx.days),
                "Peak usage %d IOPS fits within the gp3 baseline of %d IOPS and %d MiB/s"
                % (int(peak_iops), int(baseline), GP3_BASELINE_THROUGHPUT_MIBPS),
                "Multi attach is disabled",
                "The EBS volume is currently using %s storage type" % volume_type,
            ]
            savings = None
            if ctx.pricing.enabled:
                storage = storage_cost(ctx, volume_type, size_gib)
                iops = iops_cost(ctx, volume_type, provisioned_iops)
                new_cost = gp3_cost(ctx, size_gib, 0.0)
                if storage is None or iops is None or new_cost is None:
                    ctx.warn(
                        "region %s: volume %s: no pricing rate for %s storage or IOPS"
                        % (region, volume_id, volume_type)
                    )
                else:
                    savings = max(0.0, (storage + iops) - new_cost)

            rows.append(
                ctx.row(
                    resource_id=volume_id,
                    region=region,
                    description=". ".join(notes) + ".",
                    action="Move %s to gp3 with baseline IOPS and throughput" % volume_type,
                    kind="ebs-volume",
                    savings=savings,
                )
            )
            continue

        if volume_type == "io1":
            # Above the gp3 baseline, so io2 is the cheaper provisioned-IOPS home.
            notes = [
                "The EBS volume is currently using io1 storage type",
                "Peak usage %d IOPS is above the gp3 baseline of %d, so provisioned IOPS "
                "are still required" % (int(peak_iops), int(baseline)),
                "Maximum IOPS utilization is %s for the last %d+ days"
                % (pct(utilization), ctx.days),
            ]
            savings = None
            if ctx.pricing.enabled:
                now_cost = storage_cost(ctx, "io1", size_gib)
                now_iops = iops_cost(ctx, "io1", provisioned_iops)
                new_cost = storage_cost(ctx, "io2", size_gib)
                new_iops = iops_cost(ctx, "io2", provisioned_iops)
                if None in (now_cost, now_iops, new_cost, new_iops):
                    ctx.warn(
                        "region %s: volume %s: no pricing rate for io1 or io2"
                        % (region, volume_id)
                    )
                else:
                    savings = max(0.0, (now_cost + now_iops) - (new_cost + new_iops))

            rows.append(
                ctx.row(
                    resource_id=volume_id,
                    region=region,
                    description=". ".join(notes) + ".",
                    action="Move volume from io1 to io2",
                    kind="ebs-volume",
                    savings=savings,
                )
            )

    return rows


raise SystemExit(
    run_detection(
        "EBS Volume Modernization", detect, add_arguments=add_arguments
    )
)
PYTHON

#!/usr/bin/env bash
# Recommendation : Idle Filestore instances (Idle)
# Source doc     : Idle Filestore.md
#
# Detection logic:
#   1. List every Filestore instance in every location of each target project.
#   2. Keep only instances whose createTime is at least DAYS old.
#   3. Pull nfs/server/read_ops_count and nfs/server/write_ops_count with
#      ALIGN_RATE over 60-second buckets for the lookback window.
#   4. Treat any bucket below 1.0 op/sec as noise (counted as zero), convert the
#      remaining rates to operations (rate x 60) and round.
#   5. read_ops + write_ops == 0 -> the instance is idle.
#
# Usage: validate_idle_filestore.sh (-p PROJECTS | -o ORG_ID | -f FOLDER_ID) [options]
#
# Options:
#   -p PROJECTS     evaluate one project, or several as a comma-separated list
#   -o ORG_ID       evaluate every ACTIVE project under an organization
#   -f FOLDER_ID    evaluate every ACTIVE project under a folder
#   -d DAYS         lookback window and age threshold in days (default 30)
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
    MetricHttpError,
    MetricUnavailable,
    run_detection,
)

READ_OPS = "file.googleapis.com/nfs/server/read_ops_count"
WRITE_OPS = "file.googleapis.com/nfs/server/write_ops_count"

ALIGNMENT_PERIOD_SEC = 60
RATE_FLOOR = 1.0

ACTION = "Delete the Filestore instance."


def ops_total(points):
    """Rate points -> whole operations, flooring sub-1.0/s buckets to zero."""
    operations = 0.0
    for value in points:
        rate = value if value >= RATE_FLOOR else 0.0
        operations += rate * ALIGNMENT_PERIOD_SEC
    return int(round(operations))


def capacity_gib(instance):
    shares = instance.get("fileShares") or []
    for share in shares:
        capacity = share.get("capacityGb")
        if capacity:
            return float(capacity)
    return 0.0


def detect(ctx, project):
    instances = ctx.gcloud.run(["filestore", "instances", "list"], project=project) or []
    rows = []

    for instance in instances:
        # name is projects/<p>/locations/<loc>/instances/<name>
        parts = (instance.get("name") or "").split("/")
        short_name = parts[-1] if parts else ""
        location = parts[3] if len(parts) > 3 else (instance.get("locationId") or "")

        if not ctx.older_than_threshold(instance.get("createTime")):
            continue

        resource_filter = (
            ' AND resource.labels.instance_name="%s"'
            ' AND resource.labels.location="%s"' % (short_name, location)
        )

        totals = {}
        skip = False
        for label, metric in (("read", READ_OPS), ("write", WRITE_OPS)):
            try:
                points = ctx.metrics.points(
                    project,
                    metric,
                    resource_filter,
                    aligner="ALIGN_RATE",
                    alignment_period=ALIGNMENT_PERIOD_SEC,
                )
            except (MetricUnavailable, MetricHttpError) as exc:
                ctx.warn("project %s: filestore %s: %s" % (project, short_name, exc))
                skip = True
                break
            if points == NO_DATA:
                ctx.warn(
                    "project %s: filestore %s: no time series for %s"
                    % (project, short_name, metric)
                )
                skip = True
                break
            totals[label] = ops_total(points)
        if skip:
            continue

        if totals["read"] + totals["write"] > 0:
            continue

        tier = instance.get("tier", "")
        savings = (
            ctx.pricing.monthly("filestore", tier, capacity_gib(instance))
            if ctx.pricing.enabled
            else None
        )
        if ctx.pricing.enabled and savings is None:
            ctx.warn(
                "project %s: filestore %s: no pricing rate for tier %s"
                % (project, short_name, tier)
            )

        rows.append(
            ctx.row(
                project=project,
                name=short_name,
                region=location,
                description="Total Read IOPS %d, Total Write IOPS %d over the last %d days."
                % (totals["read"], totals["write"], ctx.days),
                action=ACTION,
                kind="filestore",
                savings=savings,
            )
        )
    return rows


raise SystemExit(
    run_detection("Idle Filestore Instances", detect)
)
PYTHON

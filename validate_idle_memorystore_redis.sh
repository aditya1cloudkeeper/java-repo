#!/usr/bin/env bash
# Recommendation : Memorystore for Redis - Idle instances (Over provisioned)
# Source doc     : MemoryStore Redis _ GCP Cleaner.md
#
# Detection logic:
#   1. List every Memorystore for Redis instance across all locations of each
#      target project (locations come from the API, not a hard-coded list).
#   2. Keep only instances created at least DAYS ago.
#   3. redis.googleapis.com/commands/calls   -> ALIGN_SUM over the whole window.
#      redis.googleapis.com/clients/connected -> ALIGN_MAX over the whole window.
#      Both queries filter resource.labels.instance_id on the full
#      "projects/P/locations/L/instances/N" path, which is what the
#      redis_instance monitored resource carries. The bare instance name
#      matches nothing.
#   4. Peak connections == 0                      -> nobody is connected.
#      Peak connections > 0 and total calls == 0   -> connected but no traffic.
#      Total calls > 0                             -> active, not reported.
#
# Usage: validate_idle_memorystore_redis.sh (-p PROJECTS | -o ORG_ID | -f FOLDER_ID) [options]
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
    peak,
    region_of,
    run_detection,
    total,
)

CALLS = "redis.googleapis.com/commands/calls"
CONNECTED = "redis.googleapis.com/clients/connected"


def detect(ctx, project):
    # "--region=-" asks the Redis API for every location it knows about.
    instances = (
        ctx.gcloud.run(["redis", "instances", "list", "--region", "-"], project=project) or []
    )
    rows = []

    for instance in instances:
        instance_path = instance.get("name") or ""
        parts = instance_path.split("/")
        short_name = parts[-1] if parts else ""
        location = parts[3] if len(parts) > 3 else (instance.get("locationId") or "")
        region = region_of(location)

        if not ctx.older_than_threshold(instance.get("createTime")):
            continue

        # The redis_instance monitored resource carries the FULL
        # "projects/P/locations/L/instances/N" path in its instance_id label.
        # Filtering on the bare instance name matches nothing and yields NO_DATA.
        resource_filter = ' AND resource.labels.instance_id="%s"' % instance_path
        window_seconds = ctx.days * 86400

        measurements = {}
        skip = False
        for label, metric, aligner in (
            ("calls", CALLS, "ALIGN_SUM"),
            ("connected", CONNECTED, "ALIGN_MAX"),
        ):
            try:
                points = ctx.metrics.points(
                    project,
                    metric,
                    resource_filter,
                    aligner=aligner,
                    alignment_period=window_seconds,
                )
            except (MetricUnavailable, MetricHttpError) as exc:
                ctx.warn("project %s: redis %s: %s" % (project, short_name, exc))
                skip = True
                break
            if points == NO_DATA:
                ctx.warn(
                    "project %s: redis %s: no time series for %s"
                    % (project, short_name, metric)
                )
                skip = True
                break
            measurements[label] = points
        if skip:
            continue

        total_calls = total(measurements["calls"])
        peak_connections = peak(measurements["connected"])

        if peak_connections == 0:
            description = "Redis instance has 0 connections for the last %d days." % ctx.days
            action = "Delete the Redis instance."
        elif total_calls == 0:
            description = (
                "Redis instance has active connections but no read/write activity for the "
                "last %d days." % ctx.days
            )
            action = "Delete or stop the unused Memorystore instance."
        else:
            continue

        tier = instance.get("tier", "")
        memory_gib = float(instance.get("memorySizeGb") or 0)
        savings = (
            ctx.pricing.monthly("redis", tier, memory_gib) if ctx.pricing.enabled else None
        )
        if ctx.pricing.enabled and savings is None:
            ctx.warn(
                "project %s: redis %s: no pricing rate for tier %s"
                % (project, short_name, tier or "unknown")
            )

        rows.append(
            ctx.row(
                project=project,
                name=short_name,
                region=region,
                description=description,
                action=action,
                kind="redis",
                savings=savings,
            )
        )
    return rows


raise SystemExit(
    run_detection("Idle Memorystore for Redis Instances", detect)
)
PYTHON

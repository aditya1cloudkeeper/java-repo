#!/usr/bin/env bash
# Recommendation : Cloud SQL - Idle Instances (Cleaner)
# Source doc     : Idle SQL.md
#
# Detection logic:
#   1. List every Cloud SQL instance in each target project.
#   2. Skip instances in PENDING_DELETE or UNKNOWN_STATE.
#   3. MySQL / SQL Server -> cloudsql.googleapis.com/database/network/connections
#      PostgreSQL         -> cloudsql.googleapis.com/database/postgresql/num_backends
#      filtered by resource.labels.database_id = "<project>:<instance>".
#   4. Aggregate with alignmentPeriod 86400s, ALIGN_MAX, REDUCE_MAX and take the
#      peak connection count over the lookback window.
#   5. Peak connections < 10 -> the instance is idle.
#
# Usage: validate_idle_cloudsql.sh (-p PROJECTS | -o ORG_ID | -f FOLDER_ID) [options]
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
    run_detection,
)

CONNECTION_THRESHOLD = 10
SKIP_STATES = {"PENDING_DELETE", "UNKNOWN_STATE"}

NETWORK_CONNECTIONS = "cloudsql.googleapis.com/database/network/connections"
POSTGRES_BACKENDS = "cloudsql.googleapis.com/database/postgresql/num_backends"

ACTION = "Take the backup and delete the Cloud SQL instance."


def metric_for(database_version):
    version = (database_version or "").upper()
    if "POSTGRES" in version:
        return POSTGRES_BACKENDS
    if "MYSQL" in version or "SQLSERVER" in version:
        return NETWORK_CONNECTIONS
    return None


def detect(ctx, project):
    instances = ctx.gcloud.run(["sql", "instances", "list"], project=project) or []
    rows = []

    for instance in instances:
        name = instance.get("name", "")
        state = (instance.get("state") or "").upper()
        if state in SKIP_STATES:
            continue

        database_version = instance.get("databaseVersion", "")
        metric = metric_for(database_version)
        if metric is None:
            ctx.warn(
                "project %s: instance %s: unsupported database version %s"
                % (project, name, database_version or "unknown")
            )
            continue

        database_id = "%s:%s" % (project, name)
        try:
            points = ctx.metrics.points(
                project,
                metric,
                ' AND resource.labels.database_id="%s"' % database_id,
                aligner="ALIGN_MAX",
                alignment_period=86400,
                cross_series_reducer="REDUCE_MAX",
            )
        except (MetricUnavailable, MetricHttpError) as exc:
            ctx.warn("project %s: instance %s: %s" % (project, name, exc))
            continue

        if points == NO_DATA:
            ctx.warn("project %s: instance %s: no time series for %s" % (project, name, metric))
            continue

        peak_connections = peak(points)
        if peak_connections >= CONNECTION_THRESHOLD:
            continue

        settings = instance.get("settings") or {}
        tier = settings.get("tier", "")
        savings = ctx.pricing.monthly("cloudsql", tier) if ctx.pricing.enabled else None
        if ctx.pricing.enabled and savings is None:
            ctx.warn(
                "project %s: instance %s: no pricing rate for tier %s" % (project, name, tier)
            )

        rows.append(
            ctx.row(
                project=project,
                name=name,
                region=instance.get("region", ""),
                description=(
                    "Current Database Connection Count: %d. Max database connection made to "
                    "the Cloud SQL instance is less than %d over the last %d days."
                    % (int(peak_connections), CONNECTION_THRESHOLD, ctx.days)
                ),
                action=ACTION,
                kind="sql",
                savings=savings,
            )
        )
    return rows


raise SystemExit(
    run_detection("Idle Cloud SQL Instances", detect)
)
PYTHON

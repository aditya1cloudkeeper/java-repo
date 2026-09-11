#!/usr/bin/env bash
# Recommendation : App Engine - Idle Services & Storage Hygiene Cleanup (Cleaner)
# Source doc     : Idle App Engine __ GCP Cleaner.md
#
# Detection logic:
#   1. Describe the App Engine application in each target project (one per
#      project) and keep it only if it is at least DAYS old.
#   2. List the application's services and each service's versions.
#   3. Sum appengine.googleapis.com/http/server/response_count over the lookback
#      window for the service, on the gae_app monitored resource.
#   4. Total requests <= 0 -> the service is idle.
#
#   The source doc aggregates requests per service for the report while its
#   pseudocode sums across the whole app; this script reports per service, which
#   matches the sample table.
#
# Usage: validate_idle_app_engine.sh (-p PROJECTS | -o ORG_ID | -f FOLDER_ID) [options]
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
    GcpError,
    MetricHttpError,
    MetricUnavailable,
    parse_ts,
    run_detection,
    total,
)

RESPONSE_COUNT = "appengine.googleapis.com/http/server/response_count"

TRAFFIC_THRESHOLD = 0

ACTION = (
    "Delete unused service, its versions and storage buckets or move off manual scaling"
)


def application(ctx, project):
    """Return the App Engine application, or None when the project has none."""
    try:
        return ctx.gcloud.run(["app", "describe"], project=project)
    except GcpError as exc:
        if exc.kind in ("not_found", "api_disabled", "permission_denied"):
            ctx.warn("project %s: no App Engine application (%s)" % (project, exc.summary()))
            return None
        raise


def detect(ctx, project):
    app = application(ctx, project)
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
        if not versions:
            continue

        # Require the whole service to be old enough to judge.
        created = [parse_ts(v.get("version", {}).get("createTime") or v.get("createTime"))
                   for v in versions]
        created = [moment for moment in created if moment is not None]
        if not created or min(created) > ctx.cutoff:
            continue

        resource_filter = (
            ' AND resource.type="gae_app" AND resource.labels.module_id="%s"' % service_id
        )
        try:
            points = ctx.metrics.points(
                project,
                RESPONSE_COUNT,
                resource_filter,
                aligner="ALIGN_SUM",
                alignment_period=ctx.days * 86400,
                cross_series_reducer="REDUCE_SUM",
            )
        except (MetricUnavailable, MetricHttpError) as exc:
            ctx.warn("project %s: service %s: %s" % (project, service_id, exc))
            continue

        if points == NO_DATA:
            ctx.warn(
                "project %s: service %s: no time series for %s"
                % (project, service_id, RESPONSE_COUNT)
            )
            continue

        requests = total(points)
        if requests > TRAFFIC_THRESHOLD:
            continue

        savings = (
            ctx.pricing.monthly("appengine_service", "default") if ctx.pricing.enabled else None
        )

        rows.append(
            ctx.row(
                project=project,
                name=service_id,
                region=region,
                description="No request count for the last %d+ days. Versions: %d."
                % (ctx.days, len(versions)),
                action=ACTION,
                kind="appengine-service",
                savings=savings,
            )
        )
    return rows


raise SystemExit(
    run_detection("Idle App Engine Services", detect)
)
PYTHON

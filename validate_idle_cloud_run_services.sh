#!/usr/bin/env bash
# Recommendation : Google Cloud Run - Idle Services Cleanup (Cleaner)
# Source doc     : Idle Cloud Run Services _ GCP Cleaner.md
#
# Detection logic:
#   1. List every managed Cloud Run service in each target project.
#   2. Keep only services created at least DAYS ago.
#   3. Sum run.googleapis.com/request_count over the lookback window (ALIGN_SUM).
#   4. Read the scaling configuration (minScale / manualInstanceCount).
#   5. request_count == 0 and (minScale > 0 or manualInstanceCount > 0)
#        -> idle but paying for warm instances.
#      request_count == 0 and both are 0
#        -> idle, only image storage and log retention cost remain.
#
# Usage: validate_idle_cloud_run_services.sh (-p PROJECTS | -o ORG_ID | -f FOLDER_ID) [options]
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
    total,
)

REQUEST_COUNT = "run.googleapis.com/request_count"

MIN_SCALE_KEYS = (
    "run.googleapis.com/minScale",
    "autoscaling.knative.dev/minScale",
)
MANUAL_COUNT_KEYS = ("run.googleapis.com/manualInstanceCount",)


def annotations(service):
    """Merge service-level and revision-template annotations."""
    merged = {}
    merged.update((service.get("metadata") or {}).get("annotations") or {})
    template = ((service.get("spec") or {}).get("template") or {})
    merged.update((template.get("metadata") or {}).get("annotations") or {})
    return merged


def annotation_int(values, keys):
    for key in keys:
        if key in values:
            try:
                return int(str(values[key]).strip())
            except (TypeError, ValueError):
                continue
    return 0


def detect(ctx, project):
    services = (
        ctx.gcloud.run(["run", "services", "list", "--platform", "managed"], project=project)
        or []
    )
    rows = []

    for service in services:
        metadata = service.get("metadata") or {}
        name = metadata.get("name", "")
        region = (metadata.get("labels") or {}).get("cloud.googleapis.com/location", "")

        if not ctx.older_than_threshold(metadata.get("creationTimestamp")):
            continue

        resource_filter = (
            ' AND resource.labels.service_name="%s"'
            ' AND resource.labels.location="%s"' % (name, region)
        )
        try:
            points = ctx.metrics.points(
                project,
                REQUEST_COUNT,
                resource_filter,
                aligner="ALIGN_SUM",
                alignment_period=ctx.days * 86400,
            )
        except (MetricUnavailable, MetricHttpError) as exc:
            ctx.warn("project %s: service %s: %s" % (project, name, exc))
            continue

        if points == NO_DATA:
            ctx.warn(
                "project %s: service %s: no time series for %s"
                % (project, name, REQUEST_COUNT)
            )
            continue

        requests = total(points)
        if requests > 0:
            continue

        values = annotations(service)
        min_scale = annotation_int(values, MIN_SCALE_KEYS)
        manual_count = annotation_int(values, MANUAL_COUNT_KEYS)

        if min_scale > 0 or manual_count > 0:
            description = (
                "No request count for %d+ days. This service is idle but is configured to "
                "keep instances running, which costs money." % ctx.days
            )
            action = "Set min instances to 0 and disable manual scaling."
        else:
            description = (
                "No request count for %d+ days. This service incurs no compute cost but "
                "continues to consume image storage and log retention cost." % ctx.days
            )
            action = "Delete the Cloud Run service."

        rows.append(
            ctx.row(
                project=project,
                name=name,
                region=region,
                description=description,
                action=action,
                kind="run",
            )
        )
    return rows


raise SystemExit(
    run_detection("Idle Cloud Run Services", detect)
)
PYTHON

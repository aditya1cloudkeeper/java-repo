#!/usr/bin/env bash
# Recommendation : Idle Vertex AI Endpoint / deployed model (Cleaner)
# Source doc     : GCP Gemini API Vertex AI Endpoint Cleaner Recommendation.md
#
# Detection logic:
#   1. Discover Vertex AI locations from the aiplatform locations API, then list
#      endpoints per location and keep those that have deployed models.
#   2. Sum aiplatform.googleapis.com/prediction/online/prediction_count over the
#      lookback window, filtered by resource label endpoint_id.
#   3. Endpoint total == 0  -> the endpoint is idle: recommend undeploying every
#      model on it, then stop evaluating that endpoint.
#   4. Endpoint total > 0   -> evaluate only deployed models whose createTime is
#      at least DAYS old, filtering the same metric additionally by the metric
#      label deployed_model_id. A per-model total of 0 makes that model idle.
#
#   Note endpoint_id is a resource label while deployed_model_id is a metric
#   label; the filters below reflect that.
#
# Usage: validate_idle_vertex_endpoints.sh (-p PROJECTS | -o ORG_ID | -f FOLDER_ID) [options]
#
# Options:
#   -p PROJECTS     evaluate one project, or several as a comma-separated list
#   -o ORG_ID       evaluate every ACTIVE project under an organization
#   -f FOLDER_ID    evaluate every ACTIVE project under a folder
#   -d DAYS         lookback window and model age threshold in days (default 30)
#   -R REGIONS      comma-separated locations to scan instead of discovering them
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

PREDICTION_COUNT = "aiplatform.googleapis.com/prediction/online/prediction_count"

ACTION = "Undeploy Model(s) from Vertex AI Endpoint"


def add_arguments(parser):
    parser.add_argument("-R", dest="regions")


def locations(ctx, project):
    if ctx.args.regions:
        return [item.strip() for item in ctx.args.regions.split(",") if item.strip()]
    url = "https://aiplatform.googleapis.com/v1/projects/%s/locations" % project
    try:
        payload = ctx.get_json(url)
    except MetricHttpError as exc:
        ctx.warn("project %s: cannot list Vertex AI locations: %s" % (project, exc))
        return []
    found = []
    for entry in (payload or {}).get("locations", []) or []:
        location_id = entry.get("locationId") or entry.get("name", "").rsplit("/", 1)[-1]
        if location_id:
            found.append(location_id)
    return found


def prediction_count(ctx, project, endpoint_id, model_id=None):
    resource_filter = ' AND resource.labels.endpoint_id="%s"' % endpoint_id
    if model_id:
        resource_filter += ' AND metric.labels.deployed_model_id="%s"' % model_id
    points = ctx.metrics.points(
        project,
        PREDICTION_COUNT,
        resource_filter,
        aligner="ALIGN_SUM",
        alignment_period=ctx.days * 86400,
    )
    # No series means the endpoint or model served nothing.
    return 0.0 if points == NO_DATA else total(points)


def detect(ctx, project):
    rows = []

    for location in locations(ctx, project):
        try:
            endpoints = (
                ctx.gcloud.run(
                    [
                        "ai",
                        "endpoints",
                        "list",
                        "--region",
                        location,
                        "--filter",
                        "deployedModels:*",
                    ],
                    project=project,
                )
                or []
            )
        except GcpError as exc:
            if exc.kind in ("api_disabled", "permission_denied", "not_found"):
                ctx.warn(
                    "project %s: location %s skipped: %s" % (project, location, exc.summary())
                )
                continue
            raise

        for endpoint in endpoints:
            endpoint_id = (endpoint.get("name") or "").rsplit("/", 1)[-1]
            models = endpoint.get("deployedModels") or []
            if not endpoint_id or not models:
                continue

            try:
                endpoint_total = prediction_count(ctx, project, endpoint_id)
            except (MetricUnavailable, MetricHttpError) as exc:
                ctx.warn("project %s: endpoint %s: %s" % (project, endpoint_id, exc))
                continue

            if endpoint_total == 0:
                # Case 1: the whole endpoint is idle, so every model goes.
                for model in models:
                    rows.append(
                        model_row(ctx, project, location, endpoint_id, model, ctx.days)
                    )
                continue

            # Case 2: endpoint is serving, so only aged, silent models qualify.
            for model in models:
                created = parse_ts(model.get("createTime"))
                if created is None or created > ctx.cutoff:
                    continue
                model_id = model.get("id", "")
                try:
                    model_total = prediction_count(ctx, project, endpoint_id, model_id)
                except (MetricUnavailable, MetricHttpError) as exc:
                    ctx.warn("project %s: model %s: %s" % (project, model_id, exc))
                    continue
                if model_total > 0:
                    continue
                rows.append(model_row(ctx, project, location, endpoint_id, model, ctx.days))
    return rows


def model_row(ctx, project, location, endpoint_id, model, days):
    model_id = model.get("id", "")
    machine = (
        ((model.get("dedicatedResources") or {}).get("machineSpec") or {}).get("machineType", "")
    )
    savings = (
        ctx.pricing.monthly("vertex_machine_type", machine) if ctx.pricing.enabled else None
    )
    if ctx.pricing.enabled and savings is None:
        ctx.warn(
            "project %s: model %s: no pricing rate for machine type %s"
            % (project, model_id, machine or "unset")
        )
    return ctx.row(
        project=project,
        name=endpoint_id,
        region=location,
        description="The Vertex AI deployed model %s has been idle for %d+ days."
        % (model_id, days),
        action=ACTION,
        kind="vertex-endpoint",
        link_name="%s (%s)" % (model_id, endpoint_id),
        savings=savings,
        location=location,
    )


raise SystemExit(
    run_detection(
        "Idle Vertex AI Endpoints", detect, add_arguments=add_arguments
    )
)
PYTHON

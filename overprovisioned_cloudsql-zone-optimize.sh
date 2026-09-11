#!/usr/bin/env bash
# Recommendation : Cloud SQL Zone Optimize (Overprovisioned)
# Source doc     : Overprovisioned __ Cloud SQL Zone Optimize.md
#
# Detection logic:
#   1. List Cloud SQL instances in each target project.
#   2. Keep instances whose availabilityType is REGIONAL, i.e. high availability
#      with a standby node (roughly double the compute cost of zonal).
#   3. Report only instances in non-production projects. "Non-production" is
#      matched against the project ID using -E (default: sandbox, dev, test,
#      staging, poc, qa, demo) or taken from an explicit project list via -L.
#      Production instances are expected to keep regional HA.
#
#   The source doc classifies environments during onboarding; this script uses a
#   name pattern instead, so review the matches before acting on them.
#
# Usage: validate_cloudsql_zone_optimize.sh (-p PROJECTS | -o ORG_ID | -f FOLDER_ID) [options]
#
# Options:
#   -p PROJECTS     evaluate one project, or several as a comma-separated list
#   -o ORG_ID       evaluate every ACTIVE project under an organization
#   -f FOLDER_ID    evaluate every ACTIVE project under a folder
#   -E REGEX        non-production project ID pattern
#                   (default: sandbox|dev|test|staging|poc|qa|demo)
#   -L LIST         comma-separated project IDs to treat as non-production,
#                   overriding -E
#   -d DAYS         unused by this recommendation; accepted for consistency
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
import re
import sys

sys.path.insert(0, os.environ["GCP_RECO_LIB_DIR"])

from gcp_reco_lib import run_detection

DEFAULT_NON_PROD = r"sandbox|dev|test|staging|poc|qa|demo"

ACTION = (
    "Validate ownership, take a final backup or export, schedule a maintenance window, "
    "then change availability from Regional to Zonal"
)


def add_arguments(parser):
    parser.add_argument("-E", dest="non_prod_pattern", default=DEFAULT_NON_PROD)
    parser.add_argument("-L", dest="non_prod_list")


def is_non_production(ctx, project):
    if ctx.args.non_prod_list:
        allowed = {
            item.strip() for item in ctx.args.non_prod_list.split(",") if item.strip()
        }
        return project in allowed
    try:
        return bool(re.search(ctx.args.non_prod_pattern, project, re.IGNORECASE))
    except re.error as exc:
        ctx.warn("invalid -E pattern (%s); treating no project as non-production" % exc)
        return False


def detect(ctx, project):
    if not is_non_production(ctx, project):
        return []

    instances = ctx.gcloud.run(["sql", "instances", "list"], project=project) or []
    rows = []

    for instance in instances:
        name = instance.get("name", "")
        settings = instance.get("settings") or {}
        availability = (settings.get("availabilityType") or "").upper()
        if availability != "REGIONAL":
            continue

        tier = settings.get("tier", "")
        savings = None
        if ctx.pricing.enabled:
            current = ctx.pricing.monthly("cloudsql", tier)
            if current is None:
                ctx.warn(
                    "project %s: instance %s: no pricing rate for tier %s"
                    % (project, name, tier)
                )
            else:
                # Regional HA runs a standby node, so dropping to zonal removes
                # roughly half the compute cost.
                savings = current / 2.0

        rows.append(
            ctx.row(
                project=project,
                name=name,
                region=instance.get("region", ""),
                description=(
                    "Cloud SQL instance in a non-production project is configured for high "
                    "availability (availabilityType REGIONAL), which provisions a standby "
                    "node at roughly double the compute cost of a zonal instance. Tier %s."
                    % (tier or "unknown")
                ),
                action=ACTION,
                kind="sql",
                savings=savings,
            )
        )
    return rows


raise SystemExit(
    run_detection(
        "Cloud SQL Zone Optimize", detect, add_arguments=add_arguments
    )
)
PYTHON

#!/usr/bin/env bash
# Recommendation : Cloud SQL Zone Optimize v2 (Overprovisioned)
# Source doc     : Overprovisioned __ Cloud SQL Zone Optimize.md
#
# Difference from overprovisioned_cloudsql-zone-optimize.sh
# --------------------------------------------------------
#   v1 gated every project through is_non_production(), a regex match against
#   the project ID (default "sandbox|dev|test|staging|poc|qa|demo"). Any project
#   that did not match was assumed to be production and detect() returned before
#   listing a single instance -- silently, with no warning and no bump to the
#   skipped counter.
#
#   That guess disagreed with the projects' own terraform-set "environment"
#   label in both directions: projects named "...-sand01-1" or "...-stage02"
#   were labeled non-production but read as production (savings missed), while
#   "ops-terraform-agent-sandbox" is labeled production but read as
#   non-production (would have recommended stripping HA from prod).
#
#   v2 removes the classification entirely. It reports EVERY regional instance
#   and reports the project's environment label as context so the reviewer, not
#   a regex, decides. -E and -L are therefore gone.
#
# Detection logic:
#   1. List Cloud SQL instances in each target project.
#   2. Keep instances whose availabilityType is REGIONAL, i.e. high availability
#      with a standby node (roughly double the compute cost of zonal).
#   3. Emit one row each, annotated with the project's "environment" label, the
#      instance's own env/sla labels, and whether it is a primary or a read
#      replica. No instance is filtered out on environment grounds.
#
#   Because nothing is excluded, this output WILL include production instances,
#   which are normally expected to keep regional HA. Review the environment
#   column before acting: dropping a production primary to zonal removes
#   automatic zonal failover.
#
# Usage: overprovisioned_cloudsql-zone-optimize-v2.sh (-p PROJECTS | -o ORG_ID | -f FOLDER_ID) [options]
#
# Options:
#   -p PROJECTS     evaluate one project, or several as a comma-separated list
#   -o ORG_ID       evaluate every ACTIVE project under an organization
#   -f FOLDER_ID    evaluate every ACTIVE project under a folder
#   -R              exclude read replicas (report primaries only)
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
import sys

sys.path.insert(0, os.environ["GCP_RECO_LIB_DIR"])

from gcp_reco_lib import GcpError, run_detection

ACTION_PRIMARY = (
    "Validate ownership, take a final backup or export, schedule a maintenance window, "
    "then change availability from Regional to Zonal"
)
ACTION_REPLICA = (
    "Read replica: confirm it is not serving production reads or DR, then change "
    "availability from Regional to Zonal (or delete if the replica is unused)"
)


def add_arguments(parser):
    parser.add_argument("-R", dest="skip_replicas", action="store_true")


def environment_label(ctx, project):
    """Return the project's "environment" label, or None when absent.

    This is only reported, never used to include or exclude an instance. Label
    coverage across the org is partial and the values are inconsistent
    ("production" vs "prod", "non-production" vs "nonprod" vs "testing",
    plus "shared-srv" which means neither), so it is unfit as a gate but useful
    as a hint for whoever reviews the row.
    """
    try:
        described = ctx.gcloud.run(["projects", "describe", project])
    except GcpError as exc:
        ctx.warn("project %s: cannot read project labels: %s" % (project, exc.summary()))
        return None
    if not isinstance(described, dict):
        return None
    return (described.get("labels") or {}).get("environment")


def detect(ctx, project):
    instances = ctx.gcloud.run(["sql", "instances", "list"], project=project) or []
    if not instances:
        return []

    env_label = environment_label(ctx, project)
    rows = []

    for instance in instances:
        name = instance.get("name", "")
        settings = instance.get("settings") or {}
        availability = (settings.get("availabilityType") or "").upper()
        if availability != "REGIONAL":
            continue

        instance_type = instance.get("instanceType") or ""
        is_replica = instance_type == "READ_REPLICA_INSTANCE"
        if is_replica and ctx.args.skip_replicas:
            continue

        tier = settings.get("tier", "")
        user_labels = settings.get("userLabels") or {}

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

        context_bits = [
            "Tier %s" % (tier or "unknown"),
            "instance type %s" % ("read replica" if is_replica else "primary"),
            "project environment label %s" % (env_label or "not set"),
        ]
        if user_labels.get("env"):
            context_bits.append("instance env label %s" % user_labels["env"])
        if user_labels.get("sla"):
            context_bits.append("sla %s" % user_labels["sla"])
        if is_replica and instance.get("masterInstanceName"):
            context_bits.append("master %s" % instance["masterInstanceName"])

        rows.append(
            ctx.row(
                project=project,
                name=name,
                region=instance.get("region", ""),
                description=(
                    "Cloud SQL instance is configured for high availability "
                    "(availabilityType REGIONAL), which provisions a standby node at "
                    "roughly double the compute cost of a zonal instance. %s."
                    % "; ".join(context_bits)
                ),
                action=ACTION_REPLICA if is_replica else ACTION_PRIMARY,
                kind="sql",
                savings=savings,
            )
        )
    return rows


raise SystemExit(
    run_detection(
        "Cloud SQL Zone Optimize v2", detect, add_arguments=add_arguments
    )
)
PYTHON

#!/usr/bin/env bash
# Recommendation : Memorystore for Redis -> Valkey migration (Modernization)
# Source doc     : Modernization __ Memorystore redis to valkey.md
#
# Detection logic:
#   1. List every Memorystore for Redis instance in each target project
#      ("--region -" asks the API for every location it knows, one call).
#   2. Keep only instances whose state is READY.
#   3. Keep only redisVersion in REDIS_3_2 .. REDIS_7_2.
#   4. Keep only tier BASIC or STANDARD_HA.
#   5. What is left is a migration candidate for Memorystore for Valkey 7.2.
#
# Savings: the doc puts Valkey at roughly PCT percent below the equivalent Redis
# tier, so savings = monthly Redis cost x PCT. The Redis cost comes from the
# rate card (-P), rows are "redis,<tier>,gib-hour,<rate>". Without -P the cell
# is N/A, like every other script here. -s changes PCT (default 30).
#
# Confidence is folded into Description because the seven-column layout has no
# slot for it: HIGH for REDIS_7_0 / REDIS_7_2 at 5 GB or more, LOW for
# REDIS_3_2 / REDIS_4_0, MEDIUM otherwise.
#
# Instances that are not candidates are skipped silently, except for an
# unrecognised version or tier, which is reported on stderr: a value the API
# added after this script was written should be looked at, not swallowed.
#
# READ-ONLY: lists and describes only, never creates, migrates or deletes.
#
# Usage: validate_redis_to_valkey.sh (-p PROJECTS | -o ORG_ID | -f FOLDER_ID) [options]
#
# Options:
#   -p PROJECTS     evaluate one project, or several as a comma-separated list
#   -o ORG_ID       evaluate every ACTIVE project under an organization
#   -f FOLDER_ID    evaluate every ACTIVE project under a folder
#   -d DAYS         lookback window in days (default 30; unused, no metrics)
#   -s PCT          Valkey discount versus Redis, percent (default 30)
#   -n ORG_NAME     render the Organization ID cell as "ORG_NAME (ORG_ID)"
#   -P PRICING_FILE pricing table (CSV or JSON) used for Potential Savings
#   -i SA_EMAIL     impersonate this service account for every gcloud call
#   -c CSV_FILE     also write the rows to CSV_FILE (overwrites)
#   -j              print a JSON array instead of the Markdown table
#   -F              render Region using friendly location names
#   -v              echo each gcloud invocation to stderr
#   -h              print this header and exit
#
# Permissions: redis.instances.list (roles/redis.viewer).
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
    last_segment,
    region_of,
    run_detection,
)

# Every Redis version Memorystore still supports; all of them can move to Valkey.
ELIGIBLE_VERSIONS = (
    "REDIS_3_2",
    "REDIS_4_0",
    "REDIS_5_0",
    "REDIS_6_X",
    "REDIS_7_0",
    "REDIS_7_2",
)
ELIGIBLE_TIERS = ("BASIC", "STANDARD_HA")

TARGET_ENGINE = "Memorystore for Valkey"
TARGET_VERSION = "VALKEY_7_2"

DEFAULT_DISCOUNT_PCT = 30.0

ACTION = (
    "Plan migration: 1) Create a new Memorystore for Valkey instance, "
    "2) Copy data using RIOT or redis-cli MIGRATE, "
    "3) Update application connection strings, "
    "4) Delete the old Redis instance."
)


def add_arguments(parser):
    parser.add_argument("-s", dest="discount_pct", default=str(int(DEFAULT_DISCOUNT_PCT)))


def discount_fraction(ctx):
    """Valkey discount as a fraction of the Redis cost."""
    try:
        value = float(ctx.args.discount_pct)
    except (TypeError, ValueError):
        ctx.warn("PCT (-s) is not numeric; using %d" % DEFAULT_DISCOUNT_PCT)
        return DEFAULT_DISCOUNT_PCT / 100.0
    if not 0 < value < 100:
        ctx.warn("PCT (-s) must be between 1 and 99; using %d" % DEFAULT_DISCOUNT_PCT)
        return DEFAULT_DISCOUNT_PCT / 100.0
    return value / 100.0


def confidence(version, memory_gib):
    if version in ("REDIS_7_0", "REDIS_7_2") and memory_gib >= 5:
        return "HIGH"
    if version in ("REDIS_3_2", "REDIS_4_0"):
        return "LOW"
    return "MEDIUM"


def location_of(instance):
    """Region from the resource name, falling back to locationId."""
    name = instance.get("name") or ""
    parts = name.split("/")
    if "locations" in parts:
        index = parts.index("locations")
        if index + 1 < len(parts):
            return region_of(parts[index + 1])
    return region_of(instance.get("locationId") or "")


def detect(ctx, project):
    instances = (
        ctx.gcloud.run(["redis", "instances", "list", "--region", "-"], project=project)
        or []
    )
    fraction = discount_fraction(ctx)
    rows = []

    for instance in instances:
        name = last_segment(instance.get("name", ""))
        state = (instance.get("state") or "").upper()
        version = (instance.get("redisVersion") or "").upper()
        tier = (instance.get("tier") or "").upper()
        memory_gib = int(instance.get("memorySizeGb") or 0)

        # Not a stable instance: nothing to plan against yet.
        if state != "READY":
            continue

        if version not in ELIGIBLE_VERSIONS:
            # An unknown value is worth a look; a Valkey instance is not.
            if version and not version.startswith("VALKEY"):
                ctx.warn(
                    "project %s: redis %s: unrecognised version %s, skipped"
                    % (project, name, version)
                )
            continue

        if tier not in ELIGIBLE_TIERS:
            if tier:
                ctx.warn(
                    "project %s: redis %s: unrecognised tier %s, skipped"
                    % (project, name, tier)
                )
            continue

        region = location_of(instance)

        savings = None
        if ctx.pricing.enabled:
            current_monthly = ctx.pricing.monthly("redis", tier, memory_gib)
            if current_monthly is None:
                ctx.warn(
                    "project %s: redis %s: no pricing rate for tier %s"
                    % (project, name, tier)
                )
            else:
                savings = current_monthly * fraction

        rows.append(
            ctx.row(
                project=project,
                name=name,
                region=region,
                description=(
                    "Current engine: Memorystore for Redis %s, tier %s, %d GB. "
                    "Confidence %s. %s offers up to %d%% lower cost with Redis API "
                    "compatibility. Migration is not in place: a new Valkey instance "
                    "has to be created and the data copied."
                    % (
                        version,
                        tier,
                        memory_gib,
                        confidence(version, memory_gib),
                        TARGET_ENGINE,
                        round(fraction * 100),
                    )
                ),
                action=ACTION,
                kind="redis",
                savings=savings,
                location=region,
            )
        )
    return rows


raise SystemExit(
    run_detection(
        "Memorystore Redis to Valkey Migration", detect, add_arguments=add_arguments
    )
)
PYTHON

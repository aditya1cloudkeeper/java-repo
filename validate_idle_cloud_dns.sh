#!/usr/bin/env bash
# Recommendation : Idle DNS Zones (Cleaner)
# Source doc     : IDLE Cloud DNS _ GCP-Cleaner.md
#
# Detection logic:
#   1. List every Cloud DNS managed zone in each target project.
#   2. Keep only zones created at least DAYS ago.
#   3. List each zone's record sets, ignoring the NS and SOA records that GCP
#      creates automatically with every zone.
#   4. A zone with no remaining records is idle.
#
# Usage: validate_idle_cloud_dns.sh (-p PROJECTS | -o ORG_ID | -f FOLDER_ID) [options]
#
# Options:
#   -p PROJECTS     evaluate one project, or several as a comma-separated list
#   -o ORG_ID       evaluate every ACTIVE project under an organization
#   -f FOLDER_ID    evaluate every ACTIVE project under a folder
#   -d DAYS         age threshold in days (default 30)
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
    GcpError,
    parse_ts,
    run_detection,
    ymd_phrase,
)

# Every zone is born with an NS and an SOA record; they do not count as usage.
DEFAULT_RECORD_TYPES = {"NS", "SOA"}

ACTION = "Delete the unused DNS zone."


def detect(ctx, project):
    zones = ctx.gcloud.run(["dns", "managed-zones", "list"], project=project) or []
    rows = []

    for zone in zones:
        name = zone.get("name", "")
        created = parse_ts(zone.get("creationTime"))
        if created is None or created > ctx.cutoff:
            continue

        try:
            records = (
                ctx.gcloud.run(
                    ["dns", "record-sets", "list", "--zone", name], project=project
                )
                or []
            )
        except GcpError as exc:
            ctx.warn("project %s: zone %s: record lookup failed: %s" % (project, name, exc.summary()))
            continue

        user_records = [
            record
            for record in records
            if (record.get("type") or "").upper() not in DEFAULT_RECORD_TYPES
        ]
        if user_records:
            continue

        savings = (
            ctx.pricing.monthly("dns_zone", zone.get("visibility", "default"))
            if ctx.pricing.enabled
            else None
        )
        if ctx.pricing.enabled and savings is None:
            ctx.warn("project %s: zone %s: no pricing rate for dns_zone" % (project, name))

        rows.append(
            ctx.row(
                project=project,
                name=name,
                region="global",
                description=(
                    "DNS Zone exists but has no DNS records created. DNS Zone was created "
                    "%s ago." % ymd_phrase(created, ctx.now)
                ),
                action=ACTION,
                kind="dns-zone",
                savings=savings,
            )
        )
    return rows


raise SystemExit(
    run_detection("Idle Cloud DNS Zones", detect)
)
PYTHON

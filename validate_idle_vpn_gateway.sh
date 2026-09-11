#!/usr/bin/env bash
# Recommendation : Idle VPN Gateway (Cleaner)
# Source doc     : IDLE VPN Gateway.md
#
# Detection logic:
#   1. List every HA VPN gateway (and classic target VPN gateway) in each target
#      project.
#   2. Keep only gateways created at least DAYS ago.
#   3. Sum vpn.googleapis.com/network/sent_bytes_count and
#      network/received_bytes_count over the lookback window, filtered by the
#      metric label gateway_name on the vpn_gateway monitored resource.
#   4. Both totals 0 -> the VPN gateway is idle.
#
# Usage: validate_idle_vpn_gateway.sh (-p PROJECTS | -o ORG_ID | -f FOLDER_ID) [options]
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
    last_segment,
    run_detection,
    total,
)

SENT = "vpn.googleapis.com/network/sent_bytes_count"
RECEIVED = "vpn.googleapis.com/network/received_bytes_count"

ACTION = "Delete VPN Gateway"


def list_gateways(ctx, project):
    """HA VPN gateways plus legacy classic VPN gateways."""
    gateways = []
    for command in (
        ["compute", "vpn-gateways", "list"],
        ["compute", "target-vpn-gateways", "list"],
    ):
        try:
            gateways.extend(ctx.gcloud.run(command, project=project) or [])
        except GcpError as exc:
            if exc.kind in ("api_disabled", "permission_denied", "not_found"):
                ctx.warn(
                    "project %s: %s skipped: %s"
                    % (project, " ".join(command[1:3]), exc.summary())
                )
                continue
            raise
    return gateways


def detect(ctx, project):
    rows = []
    seen = set()

    for gateway in list_gateways(ctx, project):
        name = gateway.get("name", "")
        if not name or name in seen:
            continue
        seen.add(name)

        region = last_segment(gateway.get("region", ""))
        if not ctx.older_than_threshold(gateway.get("creationTimestamp")):
            continue

        resource_filter = (
            ' AND resource.type="vpn_gateway" AND metric.labels.gateway_name="%s"' % name
        )

        traffic = {}
        skip = False
        for label, metric in (("sent", SENT), ("received", RECEIVED)):
            try:
                points = ctx.metrics.points(
                    project,
                    metric,
                    resource_filter,
                    aligner="ALIGN_SUM",
                    alignment_period=ctx.days * 86400,
                    cross_series_reducer="REDUCE_SUM",
                )
            except (MetricUnavailable, MetricHttpError) as exc:
                ctx.warn("project %s: vpn gateway %s: %s" % (project, name, exc))
                skip = True
                break
            traffic[label] = 0.0 if points == NO_DATA else total(points)
        if skip:
            continue

        if traffic["sent"] > 0 or traffic["received"] > 0:
            continue

        savings = ctx.pricing.monthly("vpn_gateway", "default") if ctx.pricing.enabled else None
        if ctx.pricing.enabled and savings is None:
            ctx.warn(
                "project %s: vpn gateway %s: no pricing rate for vpn_gateway" % (project, name)
            )

        rows.append(
            ctx.row(
                project=project,
                name=name,
                region=region,
                description=(
                    "The VPN Gateway is idle as no network activity has been recorded in the "
                    "past %d days." % ctx.days
                ),
                action=ACTION,
                savings=savings,
            )
        )
    return rows


raise SystemExit(
    run_detection("Idle VPN Gateways", detect)
)
PYTHON

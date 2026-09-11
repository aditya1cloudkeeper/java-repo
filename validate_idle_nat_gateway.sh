#!/usr/bin/env bash
# Recommendation : Idle NAT Gateway (Cleaner)
# Source doc     : idle nat gateway.md
#
# Detection logic:
#   1. List every Cloud Router in each target project and read its NAT configs.
#   2. Keep only routers created at least DAYS ago.
#   3. Pull router.googleapis.com/nat/sent_bytes_count and
#      nat/received_bytes_count for each NAT gateway over the lookback window,
#      filtered by resource labels router_id, gateway_name and region.
#   4. Both totals 0 -> the NAT gateway is idle.
#      allocated_ports is reported alongside as supporting evidence.
#
# Usage: validate_idle_nat_gateway.sh (-p PROJECTS | -o ORG_ID | -f FOLDER_ID) [options]
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
    last_segment,
    parse_ts,
    peak,
    run_detection,
    total,
    ymd_phrase,
)

SENT = "router.googleapis.com/nat/sent_bytes_count"
RECEIVED = "router.googleapis.com/nat/received_bytes_count"
ALLOCATED_PORTS = "router.googleapis.com/nat/allocated_ports"

ACTION = "Delete nat gateway"


def detect(ctx, project):
    routers = ctx.gcloud.run(["compute", "routers", "list"], project=project) or []
    rows = []

    for router in routers:
        router_name = router.get("name", "")
        router_id = str(router.get("id", ""))
        region = last_segment(router.get("region", ""))
        created = parse_ts(router.get("creationTimestamp"))

        nats = router.get("nats") or []
        if not nats:
            continue
        if created is None or created > ctx.cutoff:
            continue

        for nat in nats:
            nat_name = nat.get("name", "")
            resource_filter = (
                ' AND resource.type="nat_gateway"'
                ' AND resource.labels.router_id="%s"'
                ' AND resource.labels.gateway_name="%s"'
                ' AND resource.labels.region="%s"' % (router_id, nat_name, region)
            )

            traffic = {}
            skip = False
            for label, metric, aligner in (
                ("sent", SENT, "ALIGN_SUM"),
                ("received", RECEIVED, "ALIGN_SUM"),
                ("ports", ALLOCATED_PORTS, "ALIGN_MAX"),
            ):
                try:
                    points = ctx.metrics.points(
                        project,
                        metric,
                        resource_filter,
                        aligner=aligner,
                        alignment_period=86400,
                        cross_series_reducer="REDUCE_MAX" if label == "ports" else "REDUCE_SUM",
                    )
                except (MetricUnavailable, MetricHttpError) as exc:
                    ctx.warn("project %s: nat %s: %s" % (project, nat_name, exc))
                    skip = True
                    break
                if points == NO_DATA:
                    # No series at all means the NAT never moved a byte.
                    traffic[label] = 0.0
                    continue
                traffic[label] = peak(points) if label == "ports" else total(points)
            if skip:
                continue

            if traffic["sent"] > 0 or traffic["received"] > 0:
                continue

            savings = (
                ctx.pricing.monthly("nat_gateway", "default") if ctx.pricing.enabled else None
            )
            if ctx.pricing.enabled and savings is None:
                ctx.warn(
                    "project %s: nat %s: no pricing rate for nat_gateway" % (project, nat_name)
                )

            rows.append(
                ctx.row(
                    project=project,
                    name=nat_name,
                    region=region,
                    description=(
                        "The nat gateway has been idle for %s. Sent bytes 0, received bytes 0, "
                        "peak allocated ports %d over the last %d days. Attached to router %s."
                        % (
                            ymd_phrase(created, ctx.now),
                            int(traffic.get("ports", 0)),
                            ctx.days,
                            router_name,
                        )
                    ),
                    action=ACTION,
                    savings=savings,
                )
            )
    return rows


raise SystemExit(
    run_detection("Idle NAT Gateways", detect)
)
PYTHON

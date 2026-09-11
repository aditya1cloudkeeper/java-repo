#!/usr/bin/env bash
# Recommendation : Idle Load Balancer (Cleaner)
# Source doc     : Cleaner __ Idle Load Balancer.md
#
# Detection logic:
#   1. List every forwarding rule in each target project.
#   2. Age guard: skip rules created less than DAYS ago (not enough history).
#   3. Classify the rule from target + loadBalancingScheme + IPProtocol:
#        L7_APPLICATION    targetHttp(s)Proxies / targetGrpcProxies
#        L4_CLASSIC_PROXY  targetTcp/SslProxies, scheme EXTERNAL
#        L4_MODERN_PROXY   targetTcp/SslProxies, scheme *_MANAGED
#        L3_PASSTHROUGH    remaining TCP rules
#        UDP               IPProtocol UDP
#      Skipped: Private Service Connect (serviceAttachments / all-apis / vpc-sc),
#      non TCP/UDP protocols, and unrecognised targets.
#   4. Fetch the metric set for that class over the lookback window, daily
#      buckets. Counters use ALIGN_SUM/REDUCE_SUM, open_connections uses
#      ALIGN_MAX/REDUCE_MAX, rtt_latencies is a presence check contributing 1
#      when any point exists and 0 when the series is empty.
#   5. Idle when totalTraffic <= THRESHOLD (default 0).
#
#   Note: for this recommendation an empty timeSeries response is treated as zero
#   traffic, per the source doc, rather than as unknown.
#
# Usage: validate_idle_load_balancer.sh (-p PROJECTS | -o ORG_ID | -f FOLDER_ID) [options]
#
# Options:
#   -p PROJECTS     evaluate one project, or several as a comma-separated list
#   -o ORG_ID       evaluate every ACTIVE project under an organization
#   -f FOLDER_ID    evaluate every ACTIVE project under a folder
#   -d DAYS         lookback window and age threshold in days (default 30)
#   -T THRESHOLD    idle if totalTraffic <= THRESHOLD (default 0)
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
    run_detection,
    total,
)

ROOT = "loadbalancing.googleapis.com"

ACTION = "Recommend Deletion"

L7_TARGETS = ("targetHttpProxies", "targetHttpsProxies", "targetGrpcProxies")
PROXY_TARGETS = ("targetTcpProxies", "targetSslProxies")
PSC_TARGETS = ("all-apis", "vpc-sc")

MANAGED_SCHEMES = ("INTERNAL_MANAGED", "EXTERNAL_MANAGED")


def add_arguments(parser):
    parser.add_argument("-T", dest="threshold", default="0")


def classify(rule):
    """Return the LB class, or None when the rule must be skipped."""
    protocol = (rule.get("IPProtocol") or rule.get("ipProtocol") or "").upper()
    target = rule.get("target") or ""
    scheme = (rule.get("loadBalancingScheme") or "").upper()

    if protocol not in ("TCP", "UDP"):
        return None
    if protocol == "UDP":
        return "UDP"
    if "serviceAttachments" in target or last_segment(target) in PSC_TARGETS:
        return None
    if any(marker in target for marker in L7_TARGETS):
        return "L7_APPLICATION"
    if any(marker in target for marker in PROXY_TARGETS):
        if scheme == "EXTERNAL":
            return "L4_CLASSIC_PROXY"
        if scheme in MANAGED_SCHEMES:
            return "L4_MODERN_PROXY"
        return None
    if target or rule.get("backendService"):
        return "L3_PASSTHROUGH"
    return None


def https_prefix(rule):
    scheme = (rule.get("loadBalancingScheme") or "").upper()
    if scheme == "INTERNAL_MANAGED":
        return "%s/https/internal" % ROOT
    if scheme == "EXTERNAL_MANAGED" and rule.get("region"):
        return "%s/https/external/regional" % ROOT
    return "%s/https" % ROOT


def l3_scope(rule):
    scheme = (rule.get("loadBalancingScheme") or "").upper()
    return "internal" if scheme.startswith("INTERNAL") else "external"


def metric_plan(rule, lb_class):
    """[(metric_type, aligner, reducer, is_presence_check), ...]"""
    if lb_class == "L7_APPLICATION":
        prefix = https_prefix(rule)
        return [
            ("%s/request_count" % prefix, "ALIGN_SUM", "REDUCE_SUM", False),
            ("%s/response_bytes_count" % prefix, "ALIGN_SUM", "REDUCE_SUM", False),
        ]
    if lb_class == "L4_CLASSIC_PROXY":
        return [
            ("%s/tcp_ssl_proxy/new_connections" % ROOT, "ALIGN_SUM", "REDUCE_SUM", False),
            ("%s/tcp_ssl_proxy/open_connections" % ROOT, "ALIGN_MAX", "REDUCE_MAX", False),
        ]
    if lb_class == "L4_MODERN_PROXY":
        return [
            ("%s/l4_proxy/ingress_bytes_count" % ROOT, "ALIGN_SUM", "REDUCE_SUM", False),
            ("%s/l4_proxy/egress_bytes_count" % ROOT, "ALIGN_SUM", "REDUCE_SUM", False),
            ("%s/l4_proxy/tcp/new_connections_count" % ROOT, "ALIGN_SUM", "REDUCE_SUM", False),
        ]
    if lb_class == "L3_PASSTHROUGH":
        scope = l3_scope(rule)
        return [
            ("%s/l3/%s/ingress_bytes_count" % (ROOT, scope), "ALIGN_SUM", "REDUCE_SUM", False),
            # Health checks never complete a TCP handshake, so rtt_latencies is
            # the discriminator between probe noise and real flows.
            ("%s/l3/%s/rtt_latencies" % (ROOT, scope), "ALIGN_DELTA", "REDUCE_MEAN", True),
        ]
    if lb_class == "UDP":
        scope = l3_scope(rule)
        return [
            ("%s/l3/%s/ingress_bytes_count" % (ROOT, scope), "ALIGN_SUM", "REDUCE_SUM", False),
        ]
    return []


def detect(ctx, project):
    try:
        threshold = float(ctx.args.threshold)
    except (TypeError, ValueError):
        ctx.warn("THRESHOLD (-T) is not numeric; falling back to 0")
        threshold = 0.0

    rules = ctx.gcloud.run(["compute", "forwarding-rules", "list"], project=project) or []
    rows = []

    for rule in rules:
        name = rule.get("name", "")
        if not ctx.older_than_threshold(rule.get("creationTimestamp")):
            continue

        lb_class = classify(rule)
        if lb_class is None:
            continue

        region = last_segment(rule.get("region", "")) or "global"
        resource_filter = ' AND resource.labels.forwarding_rule_name="%s"' % name

        traffic = 0.0
        aborted = False
        for metric, aligner, reducer, presence in metric_plan(rule, lb_class):
            try:
                points = ctx.metrics.points(
                    project,
                    metric,
                    resource_filter,
                    aligner=aligner,
                    alignment_period=86400,
                    cross_series_reducer=reducer,
                )
            except (MetricUnavailable, MetricHttpError) as exc:
                ctx.warn("project %s: forwarding rule %s: %s" % (project, name, exc))
                aborted = True
                break
            # An absent metric namespace counts as zero traffic for this
            # recommendation, per the source doc.
            if points == NO_DATA:
                continue
            traffic += 1.0 if presence else total(points)
        if aborted:
            continue

        if traffic > threshold:
            continue

        savings = ctx.pricing.monthly("load_balancer", "default") if ctx.pricing.enabled else None
        if ctx.pricing.enabled and savings is None:
            ctx.warn(
                "project %s: forwarding rule %s: no pricing rate for load_balancer"
                % (project, name)
            )

        rows.append(
            ctx.row(
                project=project,
                name=name,
                region=region,
                description=(
                    "Idle Resource: This Load Balancer has not processed any traffic in the "
                    "last %d days, but is still accruing a fixed charge. Classified as %s."
                    % (ctx.days, lb_class)
                ),
                action=ACTION,
                savings=savings,
            )
        )
    return rows


raise SystemExit(
    run_detection("Idle Load Balancer", detect, add_arguments=add_arguments)
)
PYTHON

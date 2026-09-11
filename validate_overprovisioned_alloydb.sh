#!/usr/bin/env bash
# Recommendation : Over-Provisioned AlloyDB Instances (Optimization)
# Source doc     : Overprovisioned __ GCP AlloyDB.md
# Finding reason : OVER_PROVISIONED_ALLOYDB_INSTANCE
#
# Detection logic:
#   1. List AlloyDB clusters and their instances across all locations.
#   2. Eligibility: state READY, createTime at least DAYS old, and more than
#      2 vCPUs. Instances that are resizing, failed or in maintenance are skipped.
#   3. Peak CPU utilization, peak memory utilization and peak connection count
#      over the lookback window, daily buckets, ALIGN_MAX.
#   4. Utilization matrix from the source doc:
#        CPU < T and memory < T  -> reduce CPU and memory
#        CPU < T and memory >= T -> reduce CPU
#        CPU >= T and memory < T -> reduce memory
#        both >= T               -> no recommendation
#      AlloyDB machine tiers couple vCPU and memory at a fixed ratio, so any move
#      changes both. A candidate tier is therefore accepted only when the
#      projected utilization of BOTH dimensions stays at or below 70%.
#   5. Health gates: an instance is excluded when buffer cache hit ratio is below
#      -B, temp-file spill exceeds -S, or replication lag exceeds -G. When a gate
#      has no data the check is recorded as unverified in the description rather
#      than silently passed.
#   6. Connection capacity: the target tier must support the observed peak using a
#      budget of -C connections per vCPU.
#
#   The source doc names its metrics unqualified ("database/cpu/utilization") and
#   does not give thresholds for the health gates. The metric types and gate
#   defaults below are this script's assumptions; override them with the flags.
#
# Usage: validate_overprovisioned_alloydb.sh (-p PROJECTS | -o ORG_ID | -f FOLDER_ID) [options]
#
# Options:
#   -p PROJECTS     evaluate one project, or several as a comma-separated list
#   -o ORG_ID       evaluate every ACTIVE project under an organization
#   -f FOLDER_ID    evaluate every ACTIVE project under a folder
#   -d DAYS         lookback window and age threshold in days (default 30)
#   -u THRESHOLD    utilization threshold percent (default 30)
#   -C PER_VCPU     connection budget per vCPU (default 50)
#   -B RATIO        minimum acceptable buffer cache hit ratio percent (default 90)
#   -S SPILLS       maximum acceptable temp-file spill count (default 0)
#   -G SECONDS      maximum acceptable replication lag in seconds (default 10)
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
import urllib.parse

sys.path.insert(0, os.environ["GCP_RECO_LIB_DIR"])

from gcp_reco_lib import (
    NO_DATA,
    MetricHttpError,
    MetricUnavailable,
    peak,
    pct,
    run_detection,
)

ALLOYDB = "https://alloydb.googleapis.com/v1"
ROOT = "alloydb.googleapis.com/instance"

CPU = "%s/cpu/utilization" % ROOT
MEMORY = "%s/memory/utilization" % ROOT
CONNECTIONS = "%s/postgres/num_backends" % ROOT
CACHE_HIT_RATIO = "%s/postgres/blks_hit_ratio" % ROOT
TEMP_SPILL = "%s/postgres/temp_files_count" % ROOT
REPLICATION_LAG = "%s/postgres/replication/replica_lag" % ROOT

MAX_PROJECTED_UTILIZATION = 70.0
MIN_VCPU = 2

# AlloyDB machine tiers: vCPU -> GB of RAM.
TIERS = [
    (2, 16),
    (4, 32),
    (8, 64),
    (16, 128),
    (32, 256),
    (64, 512),
    (96, 768),
    (128, 864),
]

SKIP_STATES = {"CREATING", "DELETING", "FAILED", "MAINTENANCE", "BOOTSTRAPPING"}


def add_arguments(parser):
    parser.add_argument("-u", dest="utilization", default="30")
    parser.add_argument("-C", dest="per_vcpu", default="50")
    parser.add_argument("-B", dest="cache_ratio", default="90")
    parser.add_argument("-S", dest="spills", default="0")
    parser.add_argument("-G", dest="lag", default="10")


def number(ctx, value, fallback, label):
    try:
        return float(value)
    except (TypeError, ValueError):
        ctx.warn("%s is not numeric; falling back to %s" % (label, fallback))
        return float(fallback)


def paged(ctx, url, collection):
    items = []
    page_token = None
    while True:
        target = url
        if page_token:
            joiner = "&" if "?" in target else "?"
            target = "%s%spageToken=%s" % (
                target,
                joiner,
                urllib.parse.quote(page_token, safe=""),
            )
        payload = ctx.get_json(target)
        items.extend((payload or {}).get(collection, []) or [])
        page_token = (payload or {}).get("nextPageToken")
        if not page_token:
            break
    return items


def memory_for(cpu_count):
    for cpus, memory_gb in TIERS:
        if cpus == cpu_count:
            return memory_gb
    return cpu_count * 8


def smaller_tiers(cpu_count):
    return [tier for tier in TIERS if tier[0] < cpu_count][::-1]


def metric_peak(ctx, project, metric, instance_id, cluster_id):
    resource_filter = (
        ' AND resource.labels.instance_id="%s" AND resource.labels.cluster_id="%s"'
        % (instance_id, cluster_id)
    )
    points = ctx.metrics.points(
        project, metric, resource_filter, aligner="ALIGN_MAX", alignment_period=86400
    )
    return None if points == NO_DATA else peak(points)


def detect(ctx, project):
    threshold = number(ctx, ctx.args.utilization, 30, "THRESHOLD (-u)")
    per_vcpu = number(ctx, ctx.args.per_vcpu, 50, "PER_VCPU (-C)")
    min_cache = number(ctx, ctx.args.cache_ratio, 90, "RATIO (-B)")
    max_spills = number(ctx, ctx.args.spills, 0, "SPILLS (-S)")
    max_lag = number(ctx, ctx.args.lag, 10, "SECONDS (-G)")

    try:
        clusters = paged(
            ctx, "%s/projects/%s/locations/-/clusters" % (ALLOYDB, project), "clusters"
        )
    except MetricHttpError as exc:
        ctx.warn("project %s: AlloyDB cluster list unavailable: %s" % (project, exc))
        return []

    rows = []
    for cluster in clusters:
        cluster_name = cluster.get("name", "")
        if not cluster_name:
            continue
        cluster_id = cluster_name.rsplit("/", 1)[-1]
        location = cluster_name.split("/")[3] if len(cluster_name.split("/")) > 3 else ""

        try:
            instances = paged(ctx, "%s/%s/instances" % (ALLOYDB, cluster_name), "instances")
        except MetricHttpError as exc:
            ctx.warn(
                "project %s: cluster %s: instance list unavailable: %s"
                % (project, cluster_id, exc)
            )
            continue

        for instance in instances:
            name = (instance.get("name") or "").rsplit("/", 1)[-1]
            state = (instance.get("state") or "").upper()
            if state in SKIP_STATES or state != "READY":
                continue
            if not ctx.older_than_threshold(instance.get("createTime")):
                continue

            cpu_count = int(((instance.get("machineConfig") or {}).get("cpuCount") or 0))
            if cpu_count <= MIN_VCPU:
                continue
            memory_gb = memory_for(cpu_count)

            try:
                cpu = metric_peak(ctx, project, CPU, name, cluster_id)
                memory = metric_peak(ctx, project, MEMORY, name, cluster_id)
                connections = metric_peak(ctx, project, CONNECTIONS, name, cluster_id)
                cache_ratio = metric_peak(ctx, project, CACHE_HIT_RATIO, name, cluster_id)
                spills = metric_peak(ctx, project, TEMP_SPILL, name, cluster_id)
                lag = metric_peak(ctx, project, REPLICATION_LAG, name, cluster_id)
            except (MetricUnavailable, MetricHttpError) as exc:
                ctx.warn("project %s: alloydb instance %s: %s" % (project, name, exc))
                continue

            if cpu is None or memory is None:
                ctx.warn(
                    "project %s: alloydb instance %s: no CPU or memory time series"
                    % (project, name)
                )
                continue

            cpu_pct = cpu * 100.0
            memory_pct = memory * 100.0

            cpu_low = cpu_pct < threshold
            memory_low = memory_pct < threshold
            if not cpu_low and not memory_low:
                continue

            # Health gates exclude on breach; absent data is reported, not assumed.
            unverified = []
            if cache_ratio is not None:
                ratio_pct = cache_ratio * 100.0 if cache_ratio <= 1.0 else cache_ratio
                if ratio_pct < min_cache:
                    continue
            else:
                unverified.append("buffer cache hit ratio")
            if spills is not None:
                if spills > max_spills:
                    continue
            else:
                unverified.append("temp file spill activity")
            if lag is not None:
                if lag > max_lag:
                    continue
            else:
                unverified.append("replication lag")

            peak_connections = connections or 0.0

            recommended = None
            for cpus, tier_memory in smaller_tiers(cpu_count):
                if cpus < MIN_VCPU:
                    continue
                projected_cpu = cpu_pct * cpu_count / float(cpus)
                projected_memory = memory_pct * memory_gb / float(tier_memory)
                if projected_cpu > MAX_PROJECTED_UTILIZATION:
                    continue
                if projected_memory > MAX_PROJECTED_UTILIZATION:
                    continue
                if peak_connections > cpus * per_vcpu:
                    continue
                recommended = (cpus, tier_memory)
                break

            if recommended is None:
                continue
            target_cpu, target_memory = recommended

            notes = [
                "Peak CPU utilization %s" % pct(cpu_pct),
                "Peak Memory utilization %s" % pct(memory_pct),
                "Peak connections %d, within the %d per vCPU budget of the target tier"
                % (int(peak_connections), int(per_vcpu)),
            ]
            if cache_ratio is not None:
                notes.append("Buffer cache healthy")
            if lag is not None:
                notes.append("Replication lag within %.0fs" % max_lag)
            if unverified:
                notes.append("Not verified (no metric data): %s" % ", ".join(unverified))

            savings = None
            if ctx.pricing.enabled:
                cpu_delta = ctx.pricing.delta(
                    "alloydb_vcpu", "default", "default", cpu_count, target_cpu
                )
                memory_delta = ctx.pricing.delta(
                    "alloydb_memory", "default", "default", memory_gb, target_memory
                )
                if cpu_delta is None or memory_delta is None:
                    ctx.warn(
                        "project %s: alloydb instance %s: no pricing rate for "
                        "alloydb_vcpu or alloydb_memory" % (project, name)
                    )
                else:
                    savings = cpu_delta + memory_delta

            rows.append(
                ctx.row(
                    project=project,
                    name=name,
                    region=location,
                    description=". ".join(notes) + ".",
                    action="Downsize instance from %d vCPU / %d GB to %d vCPU / %d GB"
                    % (cpu_count, memory_gb, target_cpu, target_memory),
                    link_name="%s (%s)" % (name, cluster_id),
                    savings=savings,
                )
            )
    return rows


raise SystemExit(
    run_detection(
        "Overprovisioned AlloyDB Instances",
        detect,
        add_arguments=add_arguments,
    )
)
PYTHON

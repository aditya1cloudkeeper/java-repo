#!/usr/bin/env bash
# Recommendation : Overprovisioned Memorystore for Redis (Over-Provisioned)
# Source doc     : OverProvisioned _ Memory Store.md
#
# Detection logic:
#   1. List every Memorystore for Redis instance across all locations of each
#      target project ("--region -" asks the API for every location it knows).
#   2. Skip instances that are not READY and instances younger than DAYS.
#   3. redis.googleapis.com/stats/memory/usage_ratio -> ALIGN_MAX per hour with
#      REDUCE_MEAN, then the 95th percentile across the window. This is the
#      used-memory / maxmemory ratio (0..1), so 0.30 means 30 percent.
#   4. Memory p95 above THRESHOLD                      -> no recommendation.
#   5. Memory p95 at or below THRESHOLD and Redis major version < 6:
#        redis.googleapis.com/stats/cpu_utilization -> ALIGN_RATE per hour with
#        REDUCE_SUM, then the 95th percentile. p95 at or above CPU_THRESHOLD ->
#        no recommendation, the instance is compute bound and its vCPU count
#        follows its capacity tier.
#
#      Both queries filter on resource.labels.instance_id using the FULL
#      "projects/P/locations/L/instances/N" path, which is what the
#      redis_instance monitored resource carries, and on
#      metric.labels.role="primary" so a Standard HA replica is not mixed in.
#
#      stats/cpu_utilization is a DELTA counter of CPU seconds, reported split
#      across metric.labels.space (sys, user) and metric.labels.relationship
#      (parent, child). ALIGN_RATE converts it to CPU-seconds per second and
#      REDUCE_SUM recombines those four series into one figure per node, which
#      is what Google's "keep the primary below 0.8" guidance refers to. The
#      four series are disjoint, so summing them does not double count.
#   6. Redis major version >= 6 -> CPU check skipped, per the source doc.
#   7. Target capacity = (memory p95 * current capacity) / TARGET, rounded up to
#      the next whole GiB, then raised to the floor of the capacity tier:
#        M1 (1-4) and M2 (5-10) share a floor of 1 GiB, so an instance may move
#        between them. M3 (11-35), M4 (36-100) and M5 (>100) keep their own
#        floor (11 / 36 / 101 GiB) because I/O thread counts change with tier.
#        Instances with read replicas keep a 5 GiB floor (M2 is the minimum
#        tier that supports replicas).
#   8. A row is emitted only when the target capacity is below current capacity.
#
# Notes on the source doc:
#   * The doc's explainer mentions Memcached, but every rule, metric, and CLI in
#     it is Redis-only. Memcached is not evaluated here.
#   * The doc's "API calls" section names stats/memory/usage_ratio while its
#     inline sample script reads stats/memory/system_memory_usage_ratio. The
#     former is the used/maxmemory ratio the sizing rule needs, so it is used.
#   * The doc's pseudocode labels stats/cpu_utilization as a ratio, and its CLI
#     snippet aligns it with ALIGN_MAX. It is a DELTA CPU-seconds counter, so
#     ALIGN_MAX would return seconds accumulated per sample interval rather than
#     a 0..1 figure comparable to the 0.70 threshold. ALIGN_RATE is used instead.
#   * The doc's snippets call "gcloud monitoring read", which is not a gcloud
#     command. The filters themselves are correct and are what this script
#     sends through the shared Cloud Monitoring client in gcp_reco_lib.py.
#
# Usage: validate_overprovisioned_memorystore.sh (-p PROJECTS | -o ORG_ID | -f FOLDER_ID) [options]
#
# Options:
#   -p PROJECTS     evaluate one project, or several as a comma-separated list
#   -o ORG_ID       evaluate every ACTIVE project under an organization
#   -f FOLDER_ID    evaluate every ACTIVE project under a folder
#   -d DAYS         lookback window and age threshold in days (default 30)
#   -u THRESHOLD    memory utilization threshold percent (default 30)
#   -t TARGET       target memory utilization percent after resize (default 60)
#   -C CPU_PCT      CPU threshold percent, Redis < 6 only (default 70)
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
import math
import os
import sys

sys.path.insert(0, os.environ["GCP_RECO_LIB_DIR"])

from gcp_reco_lib import (
    NO_DATA,
    MetricHttpError,
    MetricUnavailable,
    pct,
    region_of,
    run_detection,
)

MEMORY_RATIO = "redis.googleapis.com/stats/memory/usage_ratio"
CPU_SECONDS = "redis.googleapis.com/stats/cpu_utilization"

HOUR = 3600
PERCENTILE = 95.0

# Capacity tiers from the Memorystore for Redis overview (References section of
# the source doc). Each entry is (tier, lower GiB, upper GiB or None for M5).
CAPACITY_TIERS = (
    ("M1", 1, 4),
    ("M2", 5, 10),
    ("M3", 11, 35),
    ("M4", 36, 100),
    ("M5", 101, None),
)

# M1 and M2 share the same minimum I/O thread count, so an instance may cross
# between them. Every other tier keeps its own lower bound.
TIER_FLOOR = {"M1": 1, "M2": 1, "M3": 11, "M4": 36, "M5": 101}

# Read replicas are only supported from M2 upwards.
REPLICA_FLOOR_GIB = 5


def add_arguments(parser):
    parser.add_argument("-u", dest="utilization", default="30")
    parser.add_argument("-t", dest="target", default="60")
    parser.add_argument("-C", dest="cpu_threshold", default="70")


def number(ctx, raw, default, label):
    try:
        value = float(raw)
    except (TypeError, ValueError):
        ctx.warn("%s is not numeric; falling back to %s" % (label, default))
        return default
    if value <= 0:
        ctx.warn("%s must be positive; falling back to %s" % (label, default))
        return default
    return value


def percentile(values, rank):
    """Linear-interpolation percentile over an unsorted list of floats."""
    if not values:
        return 0.0
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    position = (rank / 100.0) * (len(ordered) - 1)
    lower = int(math.floor(position))
    upper = int(math.ceil(position))
    if lower == upper:
        return ordered[lower]
    weight = position - lower
    return ordered[lower] + (ordered[upper] - ordered[lower]) * weight


def metric_p95(ctx, project, metric, instance_path, aligner, reducer):
    """95th percentile of hourly aligned points, or None when there is no data.

    ``instance_path`` must be the full "projects/P/locations/L/instances/N" form:
    that is what the redis_instance monitored resource carries in its
    instance_id label, not the bare instance name.
    """
    resource_filter = (
        ' AND resource.labels.instance_id="%s" AND metric.labels.role="primary"'
        % instance_path
    )
    points = ctx.metrics.points(
        project,
        metric,
        resource_filter,
        aligner=aligner,
        alignment_period=HOUR,
        cross_series_reducer=reducer,
    )
    if points == NO_DATA or not points:
        return None
    return percentile(points, PERCENTILE)


def tier_of(capacity_gib):
    for tier, lower, upper in CAPACITY_TIERS:
        if capacity_gib >= lower and (upper is None or capacity_gib <= upper):
            return tier
    return None


def major_version(redis_version):
    """REDIS_6_X -> 6, REDIS_7_0 -> 7. Returns None when unparseable."""
    parts = (redis_version or "").split("_")
    if len(parts) < 2:
        return None
    try:
        return int(parts[1])
    except ValueError:
        return None


def detect(ctx, project):
    threshold = number(ctx, ctx.args.utilization, 30.0, "THRESHOLD (-u)") / 100.0
    target = number(ctx, ctx.args.target, 60.0, "TARGET (-t)") / 100.0
    cpu_limit = number(ctx, ctx.args.cpu_threshold, 70.0, "CPU_PCT (-C)") / 100.0

    instances = (
        ctx.gcloud.run(["redis", "instances", "list", "--region", "-"], project=project) or []
    )
    rows = []

    for instance in instances:
        parts = (instance.get("name") or "").split("/")
        short_name = parts[-1] if parts else ""
        location = parts[3] if len(parts) > 3 else (instance.get("locationId") or "")
        region = region_of(location)

        if (instance.get("state") or "").upper() != "READY":
            continue
        if not ctx.older_than_threshold(instance.get("createTime")):
            continue

        capacity_gib = float(instance.get("memorySizeGb") or 0)
        if capacity_gib <= 0:
            ctx.warn(
                "project %s: redis %s: memorySizeGb not reported by the API"
                % (project, short_name)
            )
            continue

        tier = (instance.get("tier") or "").upper()
        redis_version = instance.get("redisVersion") or ""
        version = major_version(redis_version)

        capacity_tier = tier_of(capacity_gib)
        if capacity_tier is None:
            ctx.warn(
                "project %s: redis %s: capacity %g GiB is outside the M1-M5 tiers"
                % (project, short_name, capacity_gib)
            )
            continue

        instance_path = instance.get("name") or "projects/%s/locations/%s/instances/%s" % (
            project,
            location,
            short_name,
        )

        try:
            memory_p95 = metric_p95(
                ctx, project, MEMORY_RATIO, instance_path, "ALIGN_MAX", "REDUCE_MEAN"
            )
        except (MetricUnavailable, MetricHttpError) as exc:
            ctx.warn("project %s: redis %s: %s" % (project, short_name, exc))
            continue
        if memory_p95 is None:
            ctx.warn(
                "project %s: redis %s: no time series for %s"
                % (project, short_name, MEMORY_RATIO)
            )
            continue

        # Step 4: healthy or above threshold, nothing to do.
        if memory_p95 > threshold:
            continue

        # Step 5: Redis below 6 is single threaded, so a low-memory instance can
        # still be compute bound. Its vCPU count is tied to the capacity tier.
        cpu_note = "CPU check skipped (Redis %s)" % (redis_version or "unknown")
        if version is None:
            ctx.warn(
                "project %s: redis %s: unparseable redisVersion %r; applying the CPU check"
                % (project, short_name, redis_version)
            )
        if version is None or version < 6:
            try:
                cpu_p95 = metric_p95(
                    ctx, project, CPU_SECONDS, instance_path, "ALIGN_RATE", "REDUCE_SUM"
                )
            except (MetricUnavailable, MetricHttpError) as exc:
                ctx.warn("project %s: redis %s: %s" % (project, short_name, exc))
                continue
            if cpu_p95 is None:
                ctx.warn(
                    "project %s: redis %s: no time series for %s"
                    % (project, short_name, CPU_SECONDS)
                )
                continue
            if cpu_p95 >= cpu_limit:
                continue
            cpu_note = "CPU usage is %s of one thread" % pct(cpu_p95 * 100.0)

        # Step 7: size for the target utilization, then respect the tier floor.
        floor_gib = TIER_FLOOR[capacity_tier]
        replicas_enabled = (
            instance.get("readReplicasMode") or ""
        ).upper() == "READ_REPLICAS_ENABLED"
        if replicas_enabled:
            floor_gib = max(floor_gib, REPLICA_FLOOR_GIB)

        target_gib = max(floor_gib, int(math.ceil((memory_p95 * capacity_gib) / target)))

        # Step 8: only report an actual reduction.
        if target_gib >= capacity_gib:
            continue

        savings = None
        if ctx.pricing.enabled:
            savings = ctx.pricing.delta("redis", tier, tier, capacity_gib, target_gib)
            if savings is None:
                ctx.warn(
                    "project %s: redis %s: no pricing rate for tier %s"
                    % (project, short_name, tier or "unknown")
                )

        rows.append(
            ctx.row(
                project=project,
                name=short_name,
                region=region,
                location=location,
                description=(
                    "Memory utilisation is %s from last %d days. Provisioned capacity is "
                    "%g Gb (%s), engine %s, %s."
                    % (
                        pct(memory_p95 * 100.0),
                        ctx.days,
                        capacity_gib,
                        capacity_tier,
                        redis_version or "unknown",
                        cpu_note,
                    )
                ),
                action=(
                    "Downgrade memory from %g Gb to %d Gb (stays within %s)."
                    % (capacity_gib, target_gib, tier_of(target_gib) or capacity_tier)
                ),
                kind="redis",
                savings=savings,
            )
        )
    return rows


raise SystemExit(
    run_detection(
        "Overprovisioned Memorystore for Redis", detect, add_arguments=add_arguments
    )
)
PYTHON

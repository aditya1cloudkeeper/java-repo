#!/usr/bin/env bash
# Recommendation : CloudSQL Instance Optimize (Overprovisioned)
# Source doc     : Overprovisioning_ CloudSQL.md
#
# Detection logic:
#   1. List Cloud SQL instances; evaluate only RUNNABLE ones.
#   2. Max cloudsql.googleapis.com/database/cpu/utilization and
#      database/memory/utilization over the lookback window, daily buckets,
#      ALIGN_MAX, filtered by resource label database_id "<project>:<instance>".
#   3. CPU < THRESHOLD and memory < THRESHOLD -> downsize both.
#      CPU >= THRESHOLD and memory < THRESHOLD -> memory only.
#      CPU < THRESHOLD and memory >= THRESHOLD -> vCPU only.
#   4. Custom tiers (db-custom-<vcpu>-<mb>): halve the overprovisioned dimension.
#      For vCPU, if the halved value is not a valid config, walk up in steps of 2
#      until one is. For memory, only the halved value is tried.
#      Projected utilization of the untouched dimension must stay <= 70%.
#   5. Predefined tiers: move one step down inside the same family, taken from
#      "gcloud sql tiers list". An instance already smallest in its family gets
#      no recommendation.
#
# Usage: validate_overprovisioned_cloudsql.sh (-p PROJECTS | -o ORG_ID | -f FOLDER_ID) [options]
#
# Options:
#   -p PROJECTS     evaluate one project, or several as a comma-separated list
#   -o ORG_ID       evaluate every ACTIVE project under an organization
#   -f FOLDER_ID    evaluate every ACTIVE project under a folder
#   -d DAYS         lookback window in days (default 30)
#   -u THRESHOLD    utilization threshold percent (default 30)
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

from gcp_reco_lib import (
    NO_DATA,
    GcpError,
    MetricHttpError,
    MetricUnavailable,
    peak,
    pct,
    run_detection,
)

CPU = "cloudsql.googleapis.com/database/cpu/utilization"
MEMORY = "cloudsql.googleapis.com/database/memory/utilization"

TARGET_UTILIZATION = 0.60
MAX_PROJECTED_UTILIZATION = 70.0

CUSTOM_RE = re.compile(r"^db-custom-(?P<cpu>\d+)-(?P<memory>\d+)$")
PREDEFINED_RE = re.compile(r"^(?P<family>db-.+?)-(?P<cpu>\d+)$")


def add_arguments(parser):
    parser.add_argument("-u", dest="utilization", default="30")


def metric_max_pct(ctx, project, metric, instance_name):
    resource_filter = ' AND resource.labels.database_id="%s:%s"' % (project, instance_name)
    points = ctx.metrics.points(
        project, metric, resource_filter, aligner="ALIGN_MAX", alignment_period=86400
    )
    if points == NO_DATA:
        return None
    return peak(points) * 100.0


def tier_catalogue(ctx, project, cache):
    """Predefined tiers with their vCPU count and RAM, keyed by tier name."""
    if "tiers" in cache:
        return cache["tiers"]
    catalogue = {}
    try:
        tiers = ctx.gcloud.run(["sql", "tiers", "list"], project=project) or []
    except GcpError as exc:
        ctx.warn("project %s: tier list unavailable: %s" % (project, exc.summary()))
        tiers = []
    for tier in tiers:
        name = tier.get("tier", "")
        if not name or name.startswith("db-custom"):
            continue
        catalogue[name] = float(tier.get("RAM") or 0)
    cache["tiers"] = catalogue
    return catalogue


def next_smaller_predefined(catalogue, current):
    """One step down inside the same predefined family."""
    match = PREDEFINED_RE.match(current)
    if not match:
        return None
    family = match.group("family")
    current_cpu = int(match.group("cpu"))
    candidates = []
    for name in catalogue:
        other = PREDEFINED_RE.match(name)
        if not other or other.group("family") != family:
            continue
        cpu = int(other.group("cpu"))
        if cpu < current_cpu:
            candidates.append((cpu, name))
    if not candidates:
        return None
    return max(candidates)[1]


def valid_custom(cpu, memory_mb):
    """Cloud SQL custom tiers: even vCPU above 1, 256 MB steps, 0.9-6.5 GB/vCPU."""
    if cpu < 1 or (cpu > 1 and cpu % 2 != 0):
        return False
    if memory_mb % 256 != 0:
        return False
    per_vcpu_gb = (memory_mb / 1024.0) / cpu
    return 0.9 <= per_vcpu_gb <= 6.5


def detect(ctx, project):
    try:
        threshold = float(ctx.args.utilization)
    except (TypeError, ValueError):
        ctx.warn("THRESHOLD (-u) is not numeric; falling back to 30")
        threshold = 30.0

    instances = ctx.gcloud.run(["sql", "instances", "list"], project=project) or []
    cache = {}
    rows = []

    for instance in instances:
        name = instance.get("name", "")
        if (instance.get("state") or "").upper() != "RUNNABLE":
            continue

        settings = instance.get("settings") or {}
        tier = settings.get("tier", "")
        edition = (settings.get("edition") or "").upper()
        region = instance.get("region", "")

        try:
            cpu_pct = metric_max_pct(ctx, project, CPU, name)
            memory_pct = metric_max_pct(ctx, project, MEMORY, name)
        except (MetricUnavailable, MetricHttpError) as exc:
            ctx.warn("project %s: instance %s: %s" % (project, name, exc))
            continue

        if cpu_pct is None or memory_pct is None:
            ctx.warn(
                "project %s: instance %s: no CPU or memory time series" % (project, name)
            )
            continue

        cpu_low = cpu_pct < threshold
        memory_low = memory_pct < threshold
        if not cpu_low and not memory_low:
            continue

        custom = CUSTOM_RE.match(tier)
        recommended = None

        if custom:
            current_cpu = int(custom.group("cpu"))
            current_memory = int(custom.group("memory"))
            target_cpu = current_cpu
            target_memory = current_memory

            if cpu_low:
                halved = max(1, current_cpu // 2)
                # Projected CPU utilization must stay within the safety ceiling.
                for candidate in range(halved, current_cpu, 2) or [halved]:
                    projected = cpu_pct * current_cpu / float(candidate)
                    if projected <= MAX_PROJECTED_UTILIZATION and valid_custom(
                        candidate, target_memory
                    ):
                        target_cpu = candidate
                        break
            if memory_low:
                halved_memory = int((current_memory / 2.0) // 256 * 256)
                projected = memory_pct * current_memory / float(max(1, halved_memory))
                if projected <= MAX_PROJECTED_UTILIZATION and valid_custom(
                    target_cpu, halved_memory
                ):
                    target_memory = halved_memory

            if (target_cpu, target_memory) != (current_cpu, current_memory) and valid_custom(
                target_cpu, target_memory
            ):
                recommended = "db-custom-%d-%d" % (target_cpu, target_memory)
        else:
            if not (cpu_low and memory_low):
                # Predefined tiers move as a unit, so both dimensions must be low.
                continue
            catalogue = tier_catalogue(ctx, project, cache)
            recommended = next_smaller_predefined(catalogue, tier)

        if recommended is None:
            continue

        if cpu_low and memory_low:
            description = (
                "CPU and Memory are Over Provisioned. Maximum CPU utilisation is %s. "
                "Maximum Memory utilisation is %s. For the last %d+ days."
                % (pct(cpu_pct), pct(memory_pct), ctx.days)
            )
        elif cpu_low:
            description = (
                "Memory utilization is high while CPU utilization is low. Maximum CPU "
                "utilisation is %s. For the last %d+ days." % (pct(cpu_pct), ctx.days)
            )
        else:
            description = (
                "CPU utilization is high while memory utilization is low. Maximum Memory "
                "utilisation is %s. For the last %d+ days." % (pct(memory_pct), ctx.days)
            )

        savings = ctx.pricing.delta("cloudsql", tier, recommended)
        if ctx.pricing.enabled and savings is None:
            ctx.warn(
                "project %s: instance %s: no pricing rate for %s or %s"
                % (project, name, tier, recommended)
            )

        rows.append(
            ctx.row(
                project=project,
                name=name,
                region=region,
                description="%s Edition: %s." % (description, edition or "unknown"),
                action="Downsize the instance from %s to %s" % (tier, recommended),
                kind="sql",
                savings=savings,
            )
        )
    return rows


raise SystemExit(
    run_detection(
        "Overprovisioned Cloud SQL", detect, add_arguments=add_arguments
    )
)
PYTHON

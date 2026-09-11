#!/usr/bin/env bash
# Recommendation : GCS Storage Class Tier Optimization (Overprovisioned)
# Source doc     : Overprovisioned __ GCS_Storage_Class_Tier_Optimization_Recommendation.md
#
# Detection logic:
#   Phase 1  List every bucket in the project (JSON API, projection=full).
#            Skip: no creation time, created after the cutoff (now - DAYS),
#            Autoclass enabled, a lifecycle rule with a SetStorageClass or
#            Delete action, and current class in {ARCHIVE, MULTI_REGIONAL,
#            REGIONAL}.
#   Phase 2  Size from storage/total_bytes, ALIGN_MEAN over a fixed 2-day
#            window. Per-series means are summed so a bucket holding objects in
#            several storage classes is measured in full. Below MIN_GIB
#            (default 1 GiB) -> skip, which also covers empty buckets. Tiering
#            a near-empty bucket saves nothing measurable and every class
#            change carries a per-object transition cost, so small buckets are
#            noise rather than findings.
#   Phase 3  Activity from api/request_count, ALIGN_SUM, daily buckets, no
#            cross-series reducer so the method and response_code labels
#            survive for client-side filtering. Fetched in 30-day chunks from
#            newest to oldest. Only methods in {ReadObject, WriteObject,
#            DeleteObject, CopyObject, ComposeObject, RewriteObject} with
#            response_code=OK count as data access. lastActiveDay is the most
#            recent qualifying point with count > 0; because chunks are walked
#            newest first, the walk stops at the first chunk that yields one.
#   Phase 4  idleDays = days between lastActiveDay and now, or the full
#            lookback window when nothing qualifies. classifyIdleDays maps that
#            to a class, then the upgrade-only guard emits it only when its rank
#            is strictly colder than the bucket's current class.
#            STORAGE_CLASS_RANK: STANDARD/MULTI_REGIONAL/REGIONAL 0, NEARLINE 1,
#            COLDLINE 2, ARCHIVE 3.
#
#   Every call is a GET; no bucket configuration or object is ever modified.
#
# Threshold conflict in the source doc: Phase 4, the Classification prose, and
# the pseudocode comment all specify 30 / 90 / 365 idle days for NEARLINE /
# COLDLINE / ARCHIVE, while the "Idle Classification Thresholds" and
# "Classification Logic" tables specify 30 / 60 / 180. This script defaults to
# 30,90,365 (the engine-code path) and -t switches ladders.
#
# The lookback window caps idleDays, so -d also caps how cold a recommendation
# can get: with the default -d 30 only NEARLINE can ever be emitted. Use
# -d 90 to reach COLDLINE and -d 365 to reach ARCHIVE.
#
# A bucket whose size or activity fetch fails is reported and skipped, never
# scored: a failed read must not become a tiering recommendation.
#
# Usage: validate_overprovisioned_gcs_storage_class.sh (-p PROJECTS | -o ORG_ID | -f FOLDER_ID) [options]
#
# Options:
#   -p PROJECTS     evaluate one project, or several as a comma-separated list
#   -o ORG_ID       evaluate every ACTIVE project under an organization
#   -f FOLDER_ID    evaluate every ACTIVE project under a folder
#   -d DAYS         lookback window and age threshold in days (default 30)
#   -t THRESHOLDS   idle-day ladder as NEARLINE,COLDLINE,ARCHIVE
#                   (default 30,90,365; the doc's tables use 30,60,180)
#   -g MIN_GIB      minimum bucket size in GiB to report (default 1)
#   -n ORG_NAME     render the Organization ID cell as "ORG_NAME (ORG_ID)"
#   -P PRICING_FILE pricing table (CSV or JSON) used for Potential Savings
#   -i SA_EMAIL     impersonate this service account for every gcloud call
#   -c CSV_FILE     also write the rows to CSV_FILE (overwrites)
#   -j              print a JSON array instead of the Markdown table
#   -F              render Region using friendly location names
#   -v              echo each gcloud invocation to stderr
#   -h              print this header and exit
#
# Permissions: storage.buckets.list (roles/storage.legacyBucketReader or
# roles/storage.admin) and monitoring.timeSeries.list (roles/monitoring.viewer).
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
from datetime import timedelta

sys.path.insert(0, os.environ["GCP_RECO_LIB_DIR"])

from gcp_reco_lib import (
    MetricHttpError,
    MetricUnavailable,
    gib,
    parse_ts,
    rfc3339,
    run_detection,
)

STORAGE_JSON = "https://storage.googleapis.com/storage/v1"
MONITORING = "https://monitoring.googleapis.com/v3"

TOTAL_BYTES = "storage.googleapis.com/storage/total_bytes"
REQUEST_COUNT = "storage.googleapis.com/api/request_count"

# Only genuine data access counts. Metadata and listing calls are background
# platform noise and must not suppress a valid recommendation.
#
# Two deliberate deviations from the source doc's list, both verified against
# live api/request_count label values:
#   - Rewrites are reported as "RewriteObject.From" / "RewriteObject.To", never
#     as bare "RewriteObject", so exact matching on the doc's list would ignore
#     every rewrite. Methods are matched on the segment before the first dot.
#   - "MoveObject" is a real data-plane operation and is absent from the doc's
#     list; a bucket whose only traffic is moves would otherwise score as idle.
DATA_ACCESS_METHODS = frozenset(
    (
        "ReadObject",
        "WriteObject",
        "DeleteObject",
        "CopyObject",
        "ComposeObject",
        "RewriteObject",
        "MoveObject",
    )
)


def is_data_access(method):
    return (method or "").split(".", 1)[0] in DATA_ACCESS_METHODS

STORAGE_CLASS_RANK = {
    "STANDARD": 0,
    "MULTI_REGIONAL": 0,
    "REGIONAL": 0,
    "NEARLINE": 1,
    "COLDLINE": 2,
    "ARCHIVE": 3,
}

# Excluded as a source class: ARCHIVE is already coldest, the other two are
# legacy classes the recommendation does not act on.
IGNORED_STORAGE_CLASSES = frozenset(("ARCHIVE", "MULTI_REGIONAL", "REGIONAL"))

LIFECYCLE_MANAGED_ACTIONS = frozenset(("SetStorageClass", "Delete"))

MULTI_REGIONS = frozenset(("us", "eu", "asia"))

CHUNK_DAYS = 30
SIZE_WINDOW_DAYS = 2
DAY_SECONDS = 86400

DEFAULT_LADDER = "30,90,365"
DEFAULT_MIN_GIB = 1.0


def add_arguments(parser):
    parser.add_argument("-t", dest="thresholds", default=DEFAULT_LADDER)
    parser.add_argument("-g", dest="min_gib", default=str(DEFAULT_MIN_GIB))


def ladder(ctx):
    """(nearline, coldline, archive) idle-day thresholds, ascending."""
    raw = (ctx.args.thresholds or DEFAULT_LADDER).split(",")
    try:
        values = [int(part.strip()) for part in raw]
    except (TypeError, ValueError):
        ctx.warn("THRESHOLDS (-t) is not a list of integers; using %s" % DEFAULT_LADDER)
        values = [int(part) for part in DEFAULT_LADDER.split(",")]
    if len(values) != 3 or values != sorted(values) or values[0] <= 0:
        ctx.warn(
            "THRESHOLDS (-t) must be three ascending positive integers; using %s"
            % DEFAULT_LADDER
        )
        values = [int(part) for part in DEFAULT_LADDER.split(",")]
    return tuple(values)


def min_size_gib(ctx):
    """Smallest bucket worth reporting, in GiB."""
    try:
        value = float(ctx.args.min_gib)
    except (TypeError, ValueError):
        ctx.warn("MIN_GIB (-g) is not numeric; using %s" % DEFAULT_MIN_GIB)
        return DEFAULT_MIN_GIB
    if value < 0:
        ctx.warn("MIN_GIB (-g) must not be negative; using %s" % DEFAULT_MIN_GIB)
        return DEFAULT_MIN_GIB
    return value


def point_value(point):
    value = point.get("value") or {}
    for key in ("int64Value", "doubleValue"):
        if key in value:
            try:
                return float(value[key])
            except (TypeError, ValueError):
                return None
    if "distributionValue" in value:
        try:
            return float((value["distributionValue"] or {}).get("count", 0))
        except (TypeError, ValueError):
            return None
    return None


def time_series(ctx, project, metric, resource_filter, aligner, start, end,
                period=DAY_SECONDS, reducer=None):
    """Raw timeSeries list, labels and point intervals preserved."""
    params = [
        ("filter", 'metric.type="%s"%s' % (metric, resource_filter)),
        ("interval.startTime", rfc3339(start)),
        ("interval.endTime", rfc3339(end)),
        ("aggregation.alignmentPeriod", "%ds" % int(period)),
        ("aggregation.perSeriesAligner", aligner),
        ("view", "FULL"),
    ]
    if reducer:
        params.append(("aggregation.crossSeriesReducer", reducer))

    collected = []
    page_token = None
    while True:
        query = list(params)
        if page_token:
            query.append(("pageToken", page_token))
        url = "%s/projects/%s/timeSeries?%s" % (
            MONITORING,
            urllib.parse.quote(project, safe=""),
            urllib.parse.urlencode(query),
        )
        payload = ctx.get_json(url)
        if payload is None:
            raise MetricUnavailable(metric)
        collected.extend(payload.get("timeSeries") or [])
        page_token = payload.get("nextPageToken")
        if not page_token:
            break
    return collected


def buckets(ctx, project):
    found = []
    page_token = None
    while True:
        params = {"project": project, "projection": "full"}
        if page_token:
            params["pageToken"] = page_token
        payload = ctx.get_json("%s/b?%s" % (STORAGE_JSON, urllib.parse.urlencode(params)))
        found.extend((payload or {}).get("items", []) or [])
        page_token = (payload or {}).get("nextPageToken")
        if not page_token:
            break
    return found


def autoclass_enabled(bucket):
    return bool((bucket.get("autoclass") or {}).get("enabled"))


def manages_storage_lifecycle(bucket):
    """True when a lifecycle rule already tiers or deletes objects."""
    rules = ((bucket.get("lifecycle") or {}).get("rule")) or []
    for rule in rules:
        if (rule.get("action") or {}).get("type", "") in LIFECYCLE_MANAGED_ACTIONS:
            return True
    return False


def region_label(location):
    """Multi-region locations render as 'global'; dual-region keeps its code."""
    loc = (location or "").lower()
    if not loc:
        return "global"
    if loc in MULTI_REGIONS:
        return "global"
    return loc


def bucket_size_bytes(ctx, project, name):
    """Mean bytes over a 2-day window, summed across storage-class series."""
    series = time_series(
        ctx,
        project,
        TOTAL_BYTES,
        ' AND resource.labels.bucket_name="%s"' % name,
        "ALIGN_MEAN",
        ctx.now - timedelta(days=SIZE_WINDOW_DAYS),
        ctx.now,
    )
    total_bytes = 0.0
    for entry in series:
        values = [point_value(point) for point in entry.get("points") or []]
        values = [value for value in values if value is not None]
        if values:
            total_bytes += sum(values) / len(values)
    return total_bytes


def last_active_day(ctx, project, name):
    """Most recent qualifying data-access day, or None across the whole window.

    Chunks are walked newest to oldest, so the first chunk that yields a
    qualifying point also holds the most recent one and the walk can stop.
    """
    resource_filter = ' AND resource.labels.bucket_name="%s"' % name
    chunk_end = ctx.now
    while chunk_end > ctx.cutoff:
        chunk_start = max(chunk_end - timedelta(days=CHUNK_DAYS), ctx.cutoff)
        series = time_series(
            ctx,
            project,
            REQUEST_COUNT,
            resource_filter,
            "ALIGN_SUM",
            chunk_start,
            chunk_end,
        )
        newest = None
        for entry in series:
            labels = entry.get("metric", {}).get("labels", {}) or {}
            if not is_data_access(labels.get("method", "")):
                continue
            if labels.get("response_code", "") != "OK":
                continue
            for point in entry.get("points") or []:
                value = point_value(point)
                if not value or value <= 0:
                    continue
                moment = parse_ts((point.get("interval") or {}).get("endTime"))
                if moment is not None and (newest is None or moment > newest):
                    newest = moment
        if newest is not None:
            return newest
        chunk_end = chunk_start
    return None


def classify_idle_days(idle_days, thresholds):
    nearline, coldline, archive = thresholds
    if idle_days >= archive:
        return "ARCHIVE"
    if idle_days >= coldline:
        return "COLDLINE"
    if idle_days >= nearline:
        return "NEARLINE"
    return None


def upgrade_only(recommended, current):
    """Recommended class only when it is strictly colder than the current one."""
    if recommended is None:
        return None
    current_rank = STORAGE_CLASS_RANK.get((current or "").upper())
    if current_rank is None:
        return None
    if STORAGE_CLASS_RANK[recommended] <= current_rank:
        return None
    return recommended


def detect(ctx, project):
    thresholds = ladder(ctx)
    minimum_gib = min_size_gib(ctx)
    rows = []

    for bucket in buckets(ctx, project):
        name = bucket.get("name", "")
        if not name:
            continue

        created = bucket.get("timeCreated")
        if not created or not ctx.older_than_threshold(created):
            continue
        if autoclass_enabled(bucket):
            continue
        if manages_storage_lifecycle(bucket):
            continue

        current_class = (bucket.get("storageClass") or "").upper()
        if current_class in IGNORED_STORAGE_CLASSES:
            continue
        if current_class not in STORAGE_CLASS_RANK:
            ctx.warn(
                "project %s: bucket %s: unrecognised storage class %s"
                % (project, name, current_class or "unset")
            )
            continue

        try:
            size_bytes = bucket_size_bytes(ctx, project, name)
        except (MetricUnavailable, MetricHttpError) as exc:
            ctx.warn("project %s: bucket %s: size fetch failed: %s" % (project, name, exc))
            continue

        size_gib = round(gib(size_bytes), 2)
        # Empty and near-empty buckets are skipped: the saving is immaterial and
        # a class change still costs one transition operation per object.
        if size_gib < minimum_gib:
            continue

        try:
            active_on = last_active_day(ctx, project, name)
        except (MetricUnavailable, MetricHttpError) as exc:
            ctx.warn("project %s: bucket %s: activity fetch failed: %s" % (project, name, exc))
            continue

        if active_on is None:
            # Nothing qualifying in the whole window: idle for the full period.
            idle_days = ctx.days
        else:
            idle_days = (ctx.now - active_on).days

        recommended = upgrade_only(classify_idle_days(idle_days, thresholds), current_class)
        if recommended is None:
            continue

        savings = None
        if ctx.pricing.enabled:
            savings = ctx.pricing.delta("gcs_storage", current_class, recommended, size_gib)
            if savings is None:
                ctx.warn(
                    "project %s: bucket %s: no pricing rate for %s -> %s"
                    % (project, name, current_class, recommended)
                )

        location = bucket.get("location") or ""
        rows.append(
            ctx.row(
                project=project,
                name=name,
                region=region_label(location),
                description=(
                    "Storage Type: %s. Bucket Size: %.2f GB. No qualifying data access "
                    "for %d+ days, so this bucket is paying %s rates for cold data."
                    % (current_class, size_gib, idle_days, current_class)
                ),
                action=(
                    "Move bucket from %s to %s storage class."
                    % (current_class, recommended)
                ),
                kind="bucket",
                savings=savings,
            )
        )
    return rows


raise SystemExit(
    run_detection(
        "GCS Storage Class Tier Optimization", detect, add_arguments=add_arguments
    )
)
PYTHON

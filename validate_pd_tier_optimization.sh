#!/usr/bin/env bash
# Recommendation : Persistent Disk tier downgrade (Overprovisioned)
# Source         : PD tier optimization validator
#
# Not the same recommendation as validate_overprovisioned_pd.sh. That one tunes
# the provisioned IOPS / throughput knobs on disk types that have them
# (pd-extreme, hyperdisk). This one moves a disk to a cheaper *type*:
#   pd-ssd      -> pd-balanced
#   pd-balanced -> pd-standard
#
# Detection logic:
#   Phase 1  List READY disks of type pd-ssd or pd-balanced that are attached to
#            at least one instance. Skip anything attached more recently than the
#            window, since a fresh attachment has no usage history worth judging
#            (-D lifts that gate). Instances are listed once per project so each
#            attachment's deviceName maps back to its disk: Monitoring keys these
#            metrics by (instance_id, device_name), and deviceName is not always
#            the disk name.
#   Phase 2  Coarse pass. One project-wide query per ops metric, ALIGN_RATE over
#            daily buckets, no cross-series reducer so the labels survive. Peak
#            read+write >= COARSE_IOPS (1500) means the disk is busy and is
#            dropped. Four project-wide queries total, not four per disk.
#   Phase 3  Deep pass over the survivors: read/write ops and read/write bytes,
#            ALIGN_RATE over hourly buckets. A disk with fewer than 70% of the
#            expected hourly points is reported and skipped, never scored.
#   Phase 4  Confidence gate, from the observed profile:
#              pd-ssd      HIGH   p95 IOPS < 2000, max < 5000, p95 MiB/s < 120
#                          MEDIUM p99 IOPS < 4000, max < 8000
#              pd-balanced HIGH   p99 IOPS < 150, max < 500, idle > 80% of
#                                 buckets, p95 MiB/s < 30
#            Anything else is left alone.
#   Phase 5  MIG awareness. Disks are grouped by the managed instance group that
#            owns their instance (baseInstanceName prefix). A pd-balanced disk in
#            a MIXED group is dropped, because a rolling template change would
#            hit busy members too. A pd-ssd disk in a MIXED group is reported
#            and flagged for manual review.
#
# Utilization in Description is measured against the type's own provisioned
# performance, derived from size: pd-ssd 30 IOPS and 0.48 MiB/s per GB,
# pd-balanced 6 IOPS and 0.28 MiB/s per GB, both floored at 3000 IOPS. Max is
# the true peak, not a percentile.
#
# Savings come from the rate card (-P): the gib-month delta between the current
# and recommended type, doubled for regional disks, which carry two copies.
# Findings below MIN_SAVINGS ($1/month) are dropped as noise. Without -P the
# cell is N/A and nothing is filtered on price.
#
# READ-ONLY: lists, describes and reads Monitoring. Never changes a disk.
#
# Usage: validate_pd_tier_optimization.sh (-p PROJECTS | -o ORG_ID | -f FOLDER_ID) [options]
#
# Options:
#   -p PROJECTS     evaluate one project, or several as a comma-separated list
#   -o ORG_ID       evaluate every ACTIVE project under an organization
#   -f FOLDER_ID    evaluate every ACTIVE project under a folder
#   -d DAYS         metrics window and attach-age gate in days (default 30)
#   -D              drop the attach-age gate (evaluate freshly attached disks)
#   -n ORG_NAME     render the Organization ID cell as "ORG_NAME (ORG_ID)"
#   -P PRICING_FILE pricing table (CSV or JSON) used for Potential Savings
#   -i SA_EMAIL     impersonate this service account for every gcloud call
#   -c CSV_FILE     also write the rows to CSV_FILE (overwrites)
#   -j              print a JSON array instead of the Markdown table
#   -F              render Region using friendly location names
#   -v              echo each gcloud invocation to stderr
#   -h              print this header and exit
#
# Permissions: compute.disks.list, compute.instances.list,
# compute.instanceGroupManagers.list, monitoring.timeSeries.list.
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
    MONITORING_ROOT,
    MetricHttpError,
    MetricUnavailable,
    last_segment,
    pct,
    region_of,
    rfc3339,
    run_detection,
)

READ_OPS = "compute.googleapis.com/instance/disk/read_ops_count"
WRITE_OPS = "compute.googleapis.com/instance/disk/write_ops_count"
READ_BYTES = "compute.googleapis.com/instance/disk/read_bytes_count"
WRITE_BYTES = "compute.googleapis.com/instance/disk/write_bytes_count"

IN_SCOPE = ("pd-ssd", "pd-balanced")
DOWNGRADE = {"pd-ssd": "pd-balanced", "pd-balanced": "pd-standard"}

COARSE_ALIGN = 86400
DEEP_ALIGN = 3600
# A project-wide hourly query over the whole window is enough to make Monitoring
# return 503 on a busy project (720 points x every disk series in one response),
# so the deep pass walks the window in chunks and merges the results.
DEEP_CHUNK_DAYS = 7
COARSE_IOPS = 1500.0
COVERAGE = 0.70
MIN_SAVINGS = 1.0
MIB = 1024.0 * 1024.0

# Provisioned performance per GB, floored where the type has a floor.
IOPS_PER_GB = {"pd-ssd": 30.0, "pd-balanced": 6.0}
MIBPS_PER_GB = {"pd-ssd": 0.48, "pd-balanced": 0.28}
IOPS_FLOOR = 3000.0


def add_arguments(parser):
    parser.add_argument("-D", dest="skip_age_gate", action="store_true")


def series_by_device(ctx, project, metric, alignment, chunk_days=None):
    """{(instance_id, device_name): [rate, ...]} for the whole project.

    One query per metric for every disk in the project, optionally split into
    chunk_days slices. Labels are preserved by leaving the cross-series reducer
    off, which is the point: aggregating here would merge every disk into one
    series. Only max, p95/p99 and a zero count are taken from these values, so
    the order points arrive in does not matter.
    """
    if chunk_days:
        merged = {}
        window_end = ctx.metrics.end
        while window_end > ctx.metrics.start:
            window_start = max(window_end - timedelta(days=chunk_days), ctx.metrics.start)
            for key, values in _series_window(
                ctx, project, metric, alignment, window_start, window_end
            ).items():
                merged.setdefault(key, []).extend(values)
            window_end = window_start
        return merged
    return _series_window(
        ctx, project, metric, alignment, ctx.metrics.start, ctx.metrics.end
    )


def _series_window(ctx, project, metric, alignment, start, end):
    params = [
        ("filter", 'metric.type="%s"' % metric),
        ("interval.startTime", rfc3339(start)),
        ("interval.endTime", rfc3339(end)),
        ("aggregation.alignmentPeriod", "%ds" % int(alignment)),
        ("aggregation.perSeriesAligner", "ALIGN_RATE"),
        ("view", "FULL"),
    ]

    collected = {}
    page_token = None
    while True:
        query = list(params)
        if page_token:
            query.append(("pageToken", page_token))
        url = "%s/projects/%s/timeSeries?%s" % (
            MONITORING_ROOT,
            urllib.parse.quote(project, safe=""),
            urllib.parse.urlencode(query),
        )
        payload = ctx.get_json(url)
        if payload is None:
            raise MetricUnavailable(metric)
        for entry in payload.get("timeSeries") or []:
            device = (entry.get("metric", {}).get("labels", {}) or {}).get("device_name")
            instance_id = (entry.get("resource", {}).get("labels", {}) or {}).get(
                "instance_id"
            )
            if not device or not instance_id:
                continue
            values = []
            for point in entry.get("points") or []:
                value = point.get("value") or {}
                for key in ("doubleValue", "int64Value"):
                    if key in value:
                        try:
                            values.append(float(value[key]))
                        except (TypeError, ValueError):
                            pass
                        break
            collected.setdefault((instance_id, device), []).extend(values)
        page_token = payload.get("nextPageToken")
        if not page_token:
            break
    return collected


def added(*arrays):
    """Element-wise sum of rate arrays, shorter ones padded with zero."""
    longest = max((len(array) for array in arrays), default=0)
    if not longest:
        return []
    padded = [list(array) + [0.0] * (longest - len(array)) for array in arrays]
    return [sum(values) for values in zip(*padded)]


def percentile(values, target):
    if not values:
        return 0.0
    ordered = sorted(values)
    position = (target / 100.0) * (len(ordered) - 1)
    low = int(position)
    high = min(low + 1, len(ordered) - 1)
    return ordered[low] + (position - low) * (ordered[high] - ordered[low])


def provisioned_iops(disk_type, size_gb):
    return max(IOPS_FLOOR, size_gb * IOPS_PER_GB.get(disk_type, 0.0))


def provisioned_mibps(disk_type, size_gb):
    return max(1.0, size_gb * MIBPS_PER_GB.get(disk_type, 0.0))


def confidence_for(disk_type, profile):
    if disk_type == "pd-ssd":
        if (
            profile["p95_iops"] < 2000
            and profile["max_iops"] < 5000
            and profile["p95_mibps"] < 120
        ):
            return "HIGH"
        if profile["p99_iops"] < 4000 and profile["max_iops"] < 8000:
            return "MEDIUM"
    elif disk_type == "pd-balanced":
        if (
            profile["p99_iops"] < 150
            and profile["max_iops"] < 500
            and profile["idle_pct"] > 80
            and profile["p95_mibps"] < 30
        ):
            return "HIGH"
    return None


def attachment_map(ctx, project):
    """(instance_id, deviceName) -> disk name, plus instance name per id."""
    devices = {}
    instance_names = {}
    for instance in ctx.gcloud.run(["compute", "instances", "list"], project=project) or []:
        instance_id = str(instance.get("id") or "")
        if not instance_id:
            continue
        instance_names[instance_id] = instance.get("name", "")
        for attached in instance.get("disks") or []:
            device_name = attached.get("deviceName") or ""
            disk_name = last_segment(attached.get("source", "")) or device_name
            if device_name and disk_name:
                devices[(instance_id, device_name)] = disk_name
    return devices, instance_names


def mig_bases(ctx, project):
    """baseInstanceName -> MIG name."""
    bases = {}
    groups = (
        ctx.gcloud.run(["compute", "instance-groups", "managed", "list"], project=project)
        or []
    )
    for group in groups:
        name = group.get("name")
        base = group.get("baseInstanceName") or name
        if name and base:
            bases[base] = name
    return bases


def detect(ctx, project):
    disks = {}
    for disk in ctx.gcloud.run(["compute", "disks", "list"], project=project) or []:
        if (disk.get("status") or "").upper() != "READY":
            continue
        disk_type = last_segment(disk.get("type", ""))
        if disk_type not in IN_SCOPE:
            continue
        users = disk.get("users") or []
        if not users:
            continue
        name = disk.get("name", "")
        if not ctx.args.skip_age_gate and not ctx.older_than_threshold(
            disk.get("lastAttachTimestamp")
        ):
            continue
        regional = bool(disk.get("region"))
        location = last_segment(disk.get("region") or disk.get("zone") or "")
        disks[name] = {
            "name": name,
            "type": disk_type,
            "size_gb": int(disk.get("sizeGb") or 0),
            "regional": regional,
            "location": location,
            "region": region_of(location) if not regional else location,
            "instance": last_segment(users[0]),
        }

    if not disks:
        return []

    devices, instance_names = attachment_map(ctx, project)
    bases = mig_bases(ctx, project)

    # Only keys that belong to an in-scope disk are of interest.
    keys_for_disk = {}
    for key, disk_name in devices.items():
        if disk_name in disks:
            keys_for_disk.setdefault(disk_name, []).append(key)

    for name, disk in disks.items():
        disk["mig"] = None
        for base, mig_name in bases.items():
            if disk["instance"].startswith(base):
                disk["mig"] = mig_name
                break

    try:
        coarse_reads = series_by_device(ctx, project, READ_OPS, COARSE_ALIGN)
        coarse_writes = series_by_device(ctx, project, WRITE_OPS, COARSE_ALIGN)
    except (MetricUnavailable, MetricHttpError) as exc:
        ctx.warn("project %s: coarse disk metric fetch failed: %s" % (project, exc))
        return []

    def combined(store, disk_name):
        arrays = []
        for key in keys_for_disk.get(disk_name, []):
            arrays.append(store.get(key, []))
        return arrays or [[]]

    candidates = []
    busy = []
    for name in disks:
        peak = max(
            added(*(added(*combined(coarse_reads, name)), *combined(coarse_writes, name)))
            or [0.0]
        )
        if peak >= COARSE_IOPS:
            busy.append(name)
        else:
            candidates.append(name)

    if not candidates:
        return []

    try:
        read_ops = series_by_device(ctx, project, READ_OPS, DEEP_ALIGN, DEEP_CHUNK_DAYS)
        write_ops = series_by_device(ctx, project, WRITE_OPS, DEEP_ALIGN, DEEP_CHUNK_DAYS)
        read_bytes = series_by_device(ctx, project, READ_BYTES, DEEP_ALIGN, DEEP_CHUNK_DAYS)
        write_bytes = series_by_device(
            ctx, project, WRITE_BYTES, DEEP_ALIGN, DEEP_CHUNK_DAYS
        )
    except (MetricUnavailable, MetricHttpError) as exc:
        ctx.warn("project %s: hourly disk metric fetch failed: %s" % (project, exc))
        return []

    expected_points = int(ctx.days * 24 * COVERAGE)
    profiles = {}
    for name in candidates:
        iops = added(*(added(*combined(read_ops, name)), *combined(write_ops, name)))
        throughput = [
            value / MIB
            for value in added(
                *(added(*combined(read_bytes, name)), *combined(write_bytes, name))
            )
        ]
        count = len(iops)
        if count < expected_points:
            ctx.warn(
                "project %s: disk %s: insufficient coverage (%d < %d hourly points), skipped"
                % (project, name, count, expected_points)
            )
            continue
        profiles[name] = {
            "max_iops": max(iops),
            "p95_iops": percentile(iops, 95),
            "p99_iops": percentile(iops, 99),
            "max_mibps": max(throughput) if throughput else 0.0,
            "p95_mibps": percentile(throughput, 95),
            "idle_pct": (iops.count(0.0) / count) * 100.0,
            "points": count,
        }

    # A MIG is ALL_UNDERUTILIZED only when every disk it owns is a candidate that
    # passed the confidence gate; a busy or unscored member makes it MIXED.
    tracker = {}
    for name, profile in profiles.items():
        mig = disks[name]["mig"]
        if mig:
            tracker.setdefault(mig, []).append(
                confidence_for(disks[name]["type"], profile) is not None
            )
    for name in busy:
        mig = disks[name]["mig"]
        if mig:
            tracker.setdefault(mig, []).append(False)
    mig_state = {
        mig: ("ALL_UNDERUTILIZED" if all(flags) else "MIXED")
        for mig, flags in tracker.items()
    }

    rows = []
    for name, profile in profiles.items():
        disk = disks[name]
        confidence = confidence_for(disk["type"], profile)
        if confidence is None:
            continue

        state = mig_state.get(disk["mig"]) if disk["mig"] else None
        manual_review = False
        if state == "MIXED":
            if disk["type"] == "pd-balanced":
                # A rolling template change would hit the busy members too.
                continue
            manual_review = True

        recommended = DOWNGRADE[disk["type"]]
        savings = None
        if ctx.pricing.enabled:
            savings = ctx.pricing.delta("disk", disk["type"], recommended, disk["size_gb"])
            if savings is None:
                ctx.warn(
                    "project %s: disk %s: no pricing rate for %s -> %s"
                    % (project, name, disk["type"], recommended)
                )
            else:
                # Regional disks keep two copies, so both sides double.
                if disk["regional"]:
                    savings *= 2.0
                if savings < MIN_SAVINGS:
                    continue

        iops_util = profile["max_iops"] / provisioned_iops(disk["type"], disk["size_gb"]) * 100.0
        mibps_util = (
            profile["max_mibps"] / provisioned_mibps(disk["type"], disk["size_gb"]) * 100.0
        )

        description = (
            "%s %s disk, %d GB. Max IOPS utilization %s of %d provisioned, "
            "max throughput utilization %s of %.0f MiB/s provisioned. "
            "Peak %.0f IOPS, p95 %.0f IOPS, idle in %s of hourly buckets over %d days. "
            "Confidence %s."
            % (
                "Regional" if disk["regional"] else "Zonal",
                disk["type"],
                disk["size_gb"],
                pct(iops_util),
                provisioned_iops(disk["type"], disk["size_gb"]),
                pct(mibps_util),
                provisioned_mibps(disk["type"], disk["size_gb"]),
                profile["max_iops"],
                profile["p95_iops"],
                pct(profile["idle_pct"]),
                ctx.days,
                confidence,
            )
        )
        if disk["mig"]:
            description += " Managed by MIG %s (%s)." % (disk["mig"], state)

        action = (
            "Snapshot the disk and recreate it as %s, then reattach: a PD type "
            "cannot be changed in place." % recommended
        )
        if disk["mig"]:
            action = (
                "Update the MIG instance template to use %s and roll the group: "
                "changes made on the instance are reverted." % recommended
            )
        if manual_review:
            action = "Manual review: some disks in MIG %s are busy. %s" % (
                disk["mig"],
                action,
            )

        rows.append(
            ctx.row(
                project=project,
                name=name,
                region=disk["region"],
                description=description,
                action=action,
                kind="regional-disk" if disk["regional"] else "disk",
                savings=savings,
                location=disk["location"],
            )
        )
    return rows


raise SystemExit(
    run_detection(
        "Persistent Disk Tier Optimization", detect, add_arguments=add_arguments
    )
)
PYTHON

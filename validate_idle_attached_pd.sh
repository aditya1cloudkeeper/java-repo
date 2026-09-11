#!/usr/bin/env bash
# Recommendation : Idle attached Persistent Disks (Cleaner)
# Source doc     : Idle attached PD.md
#
# Detection logic:
#   1. List every Compute Engine instance in each target project.
#   2. Keep only instances created at least DAYS ago.
#   3. Consider only non-boot attached disks.
#   4. Pull compute.googleapis.com/instance/disk/max_read_ops_count and
#      max_write_ops_count filtered by metric.labels.device_name and
#      resource.labels.instance_id over the lookback window.
#   5. max read IOPS < 1 and max write IOPS < 1 -> the disk is idle.
#   6. A disk attached to several instances is reported once, and only when it is
#      idle on every attachment.
#
# Usage: validate_idle_attached_pd.sh (-p PROJECTS | -o ORG_ID | -f FOLDER_ID) [options]
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
    peak,
    run_detection,
)

READ_OPS = "compute.googleapis.com/instance/disk/max_read_ops_count"
WRITE_OPS = "compute.googleapis.com/instance/disk/max_write_ops_count"

IOPS_THRESHOLD = 1.0

ACTION = (
    "Detach the disk from the VM instance and then delete it. "
    "Take a snapshot before deleting."
)


def disk_index(ctx, project):
    index = {}
    for disk in ctx.gcloud.run(["compute", "disks", "list"], project=project) or []:
        index[disk.get("selfLink", "")] = disk
    return index


def zone_of(source_url, fallback):
    """Extract the zone (or region) segment from a disk selfLink."""
    parts = (source_url or "").split("/")
    for marker in ("zones", "regions"):
        if marker in parts:
            position = parts.index(marker)
            if position + 1 < len(parts):
                return parts[position + 1]
    return fallback


def disk_is_idle(ctx, project, instance_id, device_name, disk_name):
    """Return True when both max IOPS metrics stay below 1, None when unknown."""
    for metric in (READ_OPS, WRITE_OPS):
        resource_filter = (
            ' AND metric.labels.device_name="%s"'
            ' AND resource.labels.instance_id="%s"' % (device_name, instance_id)
        )
        try:
            points = ctx.metrics.points(
                project,
                metric,
                resource_filter,
                aligner="ALIGN_MAX",
                alignment_period=86400,
            )
        except (MetricUnavailable, MetricHttpError) as exc:
            ctx.warn("project %s: disk %s: %s" % (project, disk_name, exc))
            return None
        if points == NO_DATA:
            ctx.warn(
                "project %s: disk %s: no time series for %s" % (project, disk_name, metric)
            )
            return None
        if peak(points) >= IOPS_THRESHOLD:
            return False
    return True


def detect(ctx, project):
    instances = ctx.gcloud.run(["compute", "instances", "list"], project=project) or []
    disks = disk_index(ctx, project)

    # disk selfLink -> {"idle": bool, "instances": [names], "zone": str}
    findings = {}

    for instance in instances:
        instance_name = instance.get("name", "")
        instance_id = str(instance.get("id", ""))
        instance_zone = last_segment(instance.get("zone", ""))

        if not ctx.older_than_threshold(instance.get("creationTimestamp")):
            continue

        for attached in instance.get("disks", []) or []:
            if attached.get("boot"):
                continue
            source = attached.get("source", "")
            device_name = attached.get("deviceName", "")
            disk_name = last_segment(source) or device_name
            if not disk_name:
                continue

            verdict = disk_is_idle(ctx, project, instance_id, device_name, disk_name)
            if verdict is None:
                findings[source] = None  # unknown -> never report
                continue

            entry = findings.get(source)
            if entry is None and source in findings:
                continue
            if entry is None:
                entry = {
                    "idle": True,
                    "instances": [],
                    "zone": zone_of(source, instance_zone),
                    "name": disk_name,
                }
                findings[source] = entry
            entry["idle"] = entry["idle"] and verdict
            entry["instances"].append(instance_name)

    rows = []
    for source, entry in findings.items():
        if not entry or not entry["idle"]:
            continue
        disk = disks.get(source, {})
        disk_type = last_segment(disk.get("type", ""))
        size_gib = float(disk.get("sizeGb") or 0)
        savings = (
            ctx.pricing.monthly("disk", disk_type, size_gib) if ctx.pricing.enabled else None
        )
        if ctx.pricing.enabled and savings is None:
            ctx.warn(
                "project %s: disk %s: no pricing rate for disk type %s"
                % (project, entry["name"], disk_type or "unknown")
            )

        rows.append(
            ctx.row(
                project=project,
                name=entry["name"],
                region=entry["zone"],
                description=(
                    "The disk is attached with %s. This non-boot disk is not having any "
                    "read/write operations. IOPS usage is less than 1."
                    % ", ".join(sorted(set(entry["instances"])))
                ),
                action=ACTION,
                kind="disk",
                savings=savings,
            )
        )
    return rows


raise SystemExit(
    run_detection("Idle Attached Persistent Disks", detect)
)
PYTHON

#!/usr/bin/env bash
# Recommendation : Persistent Disk (Orphaned / unattached) (Cleaner)
# Source doc     : idle pd.md
#
# Detection logic:
#   1. List every Compute Engine disk in each target project.
#   2. Keep only disks with an empty "users" field (currently unattached).
#   3. lastDetachTimestamp at least DAYS old and no later lastAttachTimestamp
#      -> the disk has served nothing since it was detached, so it is idle.
#      A lastAttachTimestamp newer than the detach time means it was reattached,
#      so the disk is skipped.
#   4. A disk that was never attached and is older than DAYS is measured from its
#      creationTimestamp instead.
#
# Usage: validate_orphaned_pd.sh (-p PROJECTS | -o ORG_ID | -f FOLDER_ID) [options]
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
    last_segment,
    parse_ts,
    run_detection,
    ymd_phrase,
)

ACTION = "Take the snapshot and delete the persistent disk."


def detect(ctx, project):
    disks = ctx.gcloud.run(["compute", "disks", "list"], project=project) or []
    rows = []

    for disk in disks:
        if disk.get("users"):
            continue

        name = disk.get("name", "")
        detached_at = parse_ts(disk.get("lastDetachTimestamp"))
        attached_at = parse_ts(disk.get("lastAttachTimestamp"))
        created_at = parse_ts(disk.get("creationTimestamp"))

        if detached_at is not None:
            # Reattached after the detach: the disk is in use again.
            if attached_at is not None and attached_at > detached_at:
                continue
            if detached_at > ctx.cutoff:
                continue
            unattached_since = detached_at
        elif attached_at is None and created_at is not None and created_at <= ctx.cutoff:
            # Never attached to anything since it was created.
            unattached_since = created_at
        else:
            continue

        zonal = bool(disk.get("zone"))
        location = last_segment(disk.get("zone") or disk.get("region") or "")
        disk_type = last_segment(disk.get("type", ""))
        size_gib = float(disk.get("sizeGb") or 0)

        savings = (
            ctx.pricing.monthly("disk", disk_type, size_gib) if ctx.pricing.enabled else None
        )
        if ctx.pricing.enabled and savings is None:
            ctx.warn(
                "project %s: disk %s: no pricing rate for disk type %s"
                % (project, name, disk_type or "unknown")
            )

        rows.append(
            ctx.row(
                project=project,
                name=name,
                region=location,
                description="Persistent disk is not associated with any resources from %s."
                % ymd_phrase(unattached_since, ctx.now),
                action=ACTION,
                kind="disk" if zonal else "regional-disk",
                savings=savings,
            )
        )
    return rows


raise SystemExit(
    run_detection("Orphaned Persistent Disks", detect)
)
PYTHON

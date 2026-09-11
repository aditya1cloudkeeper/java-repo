#!/usr/bin/env bash
# Recommendation : Persistent Disk Snapshot (Cleaner)
# Source doc     : Idle PD Snapshot.md
#
# Detection logic:
#   1. List every Compute Engine snapshot in each target project.
#   2. Keep only snapshots older than DAYS.
#   3. Drop snapshots with autoCreated == true.
#   4. Drop snapshots whose sourceDisk carries a resourcePolicy (snapshot schedule).
#   5. Drop snapshots referenced by any machine image in the project.
#   6. Whatever remains is an idle snapshot.
#
# Usage: validate_idle_pd_snapshots.sh (-p PROJECTS | -o ORG_ID | -f FOLDER_ID) [options]
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
import json
import os
import sys

sys.path.insert(0, os.environ["GCP_RECO_LIB_DIR"])

from gcp_reco_lib import (
    GcpError,
    elapsed_days,
    parse_ts,
    run_detection,
)

GIB = float(1024 ** 3)
ACTION = "Delete snapshot."


def scheduled_disk_links(ctx, project):
    """selfLinks of disks that carry a resource policy (snapshot schedule)."""
    scheduled = set()
    for disk in ctx.gcloud.run(["compute", "disks", "list"], project=project) or []:
        if disk.get("resourcePolicies"):
            scheduled.add(disk.get("selfLink", ""))
    return scheduled


def machine_image_references(ctx, project):
    """Every string appearing in the project's machine images.

    Machine images embed snapshot selfLinks under savedDisks / sourceDisk
    fields whose exact shape varies by API version, so the whole payload is
    flattened and matched by substring.
    """
    try:
        images = ctx.gcloud.run(["compute", "machine-images", "list"], project=project) or []
    except GcpError as exc:
        if exc.kind in ("api_disabled", "permission_denied", "not_found"):
            ctx.warn("project %s: machine image lookup skipped: %s" % (project, exc.summary()))
            return ""
        raise
    return json.dumps(images)


def detect(ctx, project):
    snapshots = ctx.gcloud.run(["compute", "snapshots", "list"], project=project) or []
    if not snapshots:
        return []

    scheduled = scheduled_disk_links(ctx, project)
    image_blob = machine_image_references(ctx, project)
    rows = []

    for snapshot in snapshots:
        name = snapshot.get("name", "")
        created = parse_ts(snapshot.get("creationTimestamp"))
        if created is None or created > ctx.cutoff:
            continue
        if snapshot.get("autoCreated"):
            continue
        if snapshot.get("sourceDisk", "") in scheduled:
            continue
        self_link = snapshot.get("selfLink", "")
        if (self_link and self_link in image_blob) or (
            image_blob and '"%s"' % name in image_blob
        ):
            continue

        locations = snapshot.get("storageLocations") or []
        region = locations[0] if locations else "global"

        storage_bytes = float(snapshot.get("storageBytes") or 0)
        savings = (
            ctx.pricing.monthly("snapshot", region, storage_bytes / GIB)
            if ctx.pricing.enabled
            else None
        )
        if ctx.pricing.enabled and savings is None:
            ctx.warn(
                "project %s: snapshot %s: no pricing rate for storage location %s"
                % (project, name, region)
            )

        rows.append(
            ctx.row(
                project=project,
                name=name,
                region=region,
                description=(
                    "Snapshot is not associated with any machine image. It is not part of the "
                    "GCP snapshot schedule. It is older than %d days."
                    % int(elapsed_days(created, ctx.now))
                ),
                action=ACTION,
                kind="snapshot",
                savings=savings,
            )
        )
    return rows


raise SystemExit(
    run_detection("Idle Persistent Disk Snapshots", detect)
)
PYTHON

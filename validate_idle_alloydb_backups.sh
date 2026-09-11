#!/usr/bin/env bash
# Recommendation : Idle AlloyDB Backups (Cleaner)
# Source doc     : Cleaner __ AlloyDB Backups.md
# Finding reason : OLD_ALLOYDB_BACKUP
#
# Detection logic:
#   1. List every AlloyDB backup across all locations of each target project
#      (aggregated list, locations/-).
#   2. Keep backups whose createTime is at least DAYS old.
#   3. Keep only backups in state READY, i.e. still occupying billable storage.
#   4. Skip CONTINUOUS backups: those form the point-in-time-recovery window and
#      are governed by the cluster's retention setting rather than deleted one by
#      one.
#   5. Report the remaining backups, noting whether the source cluster still
#      exists, since a backup whose cluster is gone is the strongest candidate.
#
#   Safety: the source doc also excludes backups held for compliance, legal
#   retention, active DR policy or an in-flight restore. None of that is visible
#   through the API, so confirm ownership before deleting anything listed here.
#   Backups carrying a retention label (see -K) are skipped.
#
# Usage: validate_idle_alloydb_backups.sh (-p PROJECTS | -o ORG_ID | -f FOLDER_ID) [options]
#
# Options:
#   -p PROJECTS     evaluate one project, or several as a comma-separated list
#   -o ORG_ID       evaluate every ACTIVE project under an organization
#   -f FOLDER_ID    evaluate every ACTIVE project under a folder
#   -d DAYS         backup age threshold in days (default 30)
#   -K KEYS         comma-separated label keys that mark a backup as retained
#                   (default: retain,retention,legal-hold,compliance)
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
    MetricHttpError,
    elapsed_days,
    gib,
    parse_ts,
    run_detection,
)

ALLOYDB = "https://alloydb.googleapis.com/v1"

DEFAULT_RETENTION_KEYS = "retain,retention,legal-hold,compliance"

ACTION = "Delete stale AlloyDB backup"


def add_arguments(parser):
    parser.add_argument("-K", dest="retention_keys", default=DEFAULT_RETENTION_KEYS)


def paged(ctx, url, collection):
    """Follow nextPageToken on an AlloyDB list endpoint."""
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


def cluster_names(ctx, project):
    """Fully qualified names of clusters that still exist."""
    try:
        clusters = paged(
            ctx, "%s/projects/%s/locations/-/clusters" % (ALLOYDB, project), "clusters"
        )
    except MetricHttpError as exc:
        ctx.warn("project %s: cluster list unavailable: %s" % (project, exc))
        return None
    return {cluster.get("name", "") for cluster in clusters}


def detect(ctx, project):
    retention_keys = {
        key.strip().lower()
        for key in (ctx.args.retention_keys or "").split(",")
        if key.strip()
    }

    try:
        backups = paged(
            ctx, "%s/projects/%s/locations/-/backups" % (ALLOYDB, project), "backups"
        )
    except MetricHttpError as exc:
        ctx.warn("project %s: AlloyDB backup list unavailable: %s" % (project, exc))
        return []

    if not backups:
        return []

    live_clusters = cluster_names(ctx, project)
    rows = []

    for backup in backups:
        full_name = backup.get("name", "")
        parts = full_name.split("/")
        backup_id = parts[-1] if parts else ""
        location = parts[3] if len(parts) > 3 else ""

        created = parse_ts(backup.get("createTime"))
        if created is None or created > ctx.cutoff:
            continue

        state = (backup.get("state") or "").upper()
        if state != "READY":
            continue

        backup_type = (backup.get("type") or "").upper()
        if backup_type == "CONTINUOUS":
            continue

        labels = {key.lower() for key in (backup.get("labels") or {})}
        if labels & retention_keys:
            continue

        cluster = backup.get("clusterName", "")
        cluster_id = cluster.rsplit("/", 1)[-1] if cluster else "unknown"
        size_bytes = float(backup.get("sizeBytes") or 0)
        size_gib = gib(size_bytes)
        age_days = int(elapsed_days(created, ctx.now))

        notes = [
            "AlloyDB backup is %d days old" % age_days,
            "Backup continues generating storage charges (%.2f GiB)" % size_gib,
        ]
        if live_clusters is not None:
            if cluster and cluster not in live_clusters:
                notes.append("Source cluster %s no longer exists" % cluster_id)
            else:
                notes.append("Source cluster %s still exists" % cluster_id)
        if backup_type:
            notes.append("Backup type %s" % backup_type)

        savings = (
            ctx.pricing.monthly("alloydb_backup_storage", location, size_gib)
            if ctx.pricing.enabled
            else None
        )
        if ctx.pricing.enabled and savings is None:
            ctx.warn(
                "project %s: backup %s: no pricing rate for alloydb_backup_storage"
                % (project, backup_id)
            )

        rows.append(
            ctx.row(
                project=project,
                name=backup_id,
                region=location,
                description=". ".join(notes) + ".",
                action=ACTION,
                savings=savings,
            )
        )
    return rows


raise SystemExit(
    run_detection(
        "Idle AlloyDB Backups", detect, add_arguments=add_arguments
    )
)
PYTHON

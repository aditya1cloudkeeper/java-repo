#!/usr/bin/env bash
# Recommendation : Compute Engine - Stopped VM Instances (Cleaner)
# Source doc     : IDLE VM Instance.md
#
# Detection logic:
#   1. List every Compute Engine instance in each target project.
#   2. Keep only instances whose status is TERMINATED.
#   3. Keep only instances whose lastStopTimestamp is at least DAYS old.
#   4. Potential savings = machine type + every attached persistent disk.
#
# Usage: validate_stopped_vm_instances.sh (-p PROJECTS | -o ORG_ID | -f FOLDER_ID) [options]
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

ACTION = (
    "Delete Stopped VM Instance and Its Attached PD. Ensure to take a backup of the "
    "machine image before deleting the VM Instance"
)


def disk_index(ctx, project):
    """Map disk selfLink -> (type, sizeGb) so savings can include attached PDs."""
    index = {}
    for disk in ctx.gcloud.run(["compute", "disks", "list"], project=project) or []:
        index[disk.get("selfLink", "")] = (
            last_segment(disk.get("type", "")),
            float(disk.get("sizeGb") or 0),
        )
    return index


def instance_savings(ctx, project, instance, disks):
    if not ctx.pricing.enabled:
        return None
    machine_type = last_segment(instance.get("machineType", ""))
    amount = ctx.pricing.monthly("machine_type", machine_type)
    if amount is None:
        ctx.warn(
            "project %s: instance %s: no pricing rate for machine type %s"
            % (project, instance.get("name"), machine_type)
        )
        amount = 0.0
    for attached in instance.get("disks", []) or []:
        source = attached.get("source", "")
        disk_type, size_gib = disks.get(source, (None, float(attached.get("diskSizeGb") or 0)))
        if disk_type is None:
            ctx.warn(
                "project %s: instance %s: attached disk %s not found in disk list"
                % (project, instance.get("name"), last_segment(source) or "unknown")
            )
            continue
        disk_amount = ctx.pricing.monthly("disk", disk_type, size_gib)
        if disk_amount is None:
            ctx.warn(
                "project %s: disk %s: no pricing rate for disk type %s"
                % (project, last_segment(source), disk_type)
            )
            continue
        amount += disk_amount
    return amount


def detect(ctx, project):
    instances = ctx.gcloud.run(["compute", "instances", "list"], project=project) or []
    disks = disk_index(ctx, project) if ctx.pricing.enabled else {}
    rows = []

    for instance in instances:
        if instance.get("status") != "TERMINATED":
            continue

        name = instance.get("name", "")
        stopped_at = parse_ts(instance.get("lastStopTimestamp"))
        if stopped_at is None:
            ctx.warn(
                "project %s: instance %s is TERMINATED but has no lastStopTimestamp"
                % (project, name)
            )
            continue
        if stopped_at > ctx.cutoff:
            continue

        zone = last_segment(instance.get("zone", ""))
        rows.append(
            ctx.row(
                project=project,
                name=name,
                region=zone,
                description="The VM Instance has been stopped for %s."
                % ymd_phrase(stopped_at, ctx.now),
                action=ACTION,
                kind="instance",
                link_name="%s (%s)" % (name, instance.get("id", "")),
                savings=instance_savings(ctx, project, instance, disks),
            )
        )
    return rows


raise SystemExit(
    run_detection("Stopped VM Instances", detect)
)
PYTHON

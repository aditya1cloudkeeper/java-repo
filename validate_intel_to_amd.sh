#!/usr/bin/env bash
#
# validate_intel_to_amd.sh
#
# Validates the "VM Instance Modernization: Intel -> AMD" recommendation.
#
# Identifies Intel-based Compute Engine VMs that have a cheaper AMD-based
# machine type with identical vCPU/memory, for both standalone and MIG VMs.
#
# Finding reasons (per the doc):
#   INTEL_STANDALONE_ELIGIBLE  Standalone Intel VM with an AMD equivalent.
#   INTEL_MIG_ELIGIBLE         MIG-managed Intel VM (migrate via new template
#                              + rolling update).
#   INTEL_NO_AMD_EQUIVALENT    Intel VM with no cost-effective AMD equivalent.
#
# Efficiency: ONE gcloud call per project. `instances list --format=json`
# already returns machineType, cpuPlatform, status and metadata, so the
# per-VM `describe` loop in the doc is unnecessary.
#
# READ-ONLY: classification only; never stops or modifies any VM.
#
# Requirements: gcloud CLI (authenticated), python3.
# Permissions: compute.instances.list (+ .get implied by list output).
#
# Usage:
#   ./validate_intel_to_amd.sh -p PROJECT_ID[,PROJECT2,...] [-p MORE] [-f FILE] [-a] [-j] [-w N] [-c CSV]
#
# Options:
#   -p PROJECTS     GCP project(s) to scan. Comma-separated and/or repeated.
#   -f FILE         Read project IDs from FILE (one per line; # comments ok).
#   -w N            Max parallel project scans (default: 10).
#   -a              Show all VMs (including AMD/Arm already-optimized ones)
#   -j              Emit results as JSON instead of a table
#   -c CSV          Also write results to CSV at this path
#   -h              Show this help
#
# Exit codes: 0 ok | 1 bad args/missing dep | 2 gcloud failure

set -euo pipefail

PROJECTS=()
PROJECT_FILE=""
WORKERS=10
SHOW_ALL=false
OUTPUT_JSON=false
CSV_FILE=""

err()  { printf 'ERROR: %s\n' "$*" >&2; }
info() { printf '%s\n' "$*" >&2; }
usage() { sed -n '2,/^# Exit codes/p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while getopts ":p:f:w:c:ajh" opt; do
  case "$opt" in
    p) IFS=',' read -ra _ps <<< "$OPTARG"; PROJECTS+=("${_ps[@]}") ;;
    f) PROJECT_FILE="$OPTARG" ;;
    w) WORKERS="$OPTARG" ;;
    a) SHOW_ALL=true ;;
    j) OUTPUT_JSON=true ;;
    c) CSV_FILE="$OPTARG" ;;
    h) usage 0 ;;
    :) err "Option -$OPTARG requires an argument."; usage 1 ;;
    \?) err "Unknown option: -$OPTARG"; usage 1 ;;
  esac
done

command -v gcloud  >/dev/null 2>&1 || { err "gcloud CLI not found on PATH."; exit 1; }
command -v python3 >/dev/null 2>&1 || { err "python3 not found on PATH."; exit 1; }
[[ "$WORKERS" =~ ^[0-9]+$ ]] && [[ "$WORKERS" -gt 0 ]] || { err "WORKERS (-w) must be a positive integer."; exit 1; }

if [[ -n "$PROJECT_FILE" ]]; then
  [[ -f "$PROJECT_FILE" ]] || { err "Project file not found: $PROJECT_FILE"; exit 1; }
  while IFS= read -r line; do
    line="${line%%#*}"; line="$(echo "$line" | tr -d '[:space:]')"
    [[ -n "$line" ]] && PROJECTS+=("$line")
  done < "$PROJECT_FILE"
fi

# De-duplicate while preserving order.
declare -A _seen; _uniq=()
for p in "${PROJECTS[@]:-}"; do
  [[ -z "$p" ]] && continue
  [[ -n "${_seen[$p]:-}" ]] && continue
  _seen[$p]=1; _uniq+=("$p")
done
PROJECTS=("${_uniq[@]:-}")
[[ "${#PROJECTS[@]}" -gt 0 && -n "${PROJECTS[0]:-}" ]] || { err "At least one project is required (-p or -f)."; usage 1; }

# --- fetch instances for all projects in parallel --------------------------
WORKDIR="$(mktemp -d /tmp/intel_amd.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

fetch_one() {
  local proj="$1" out="$2"
  if gcloud compute instances list --project="$proj" --format="json" >"$out.tmp" 2>"$out.err"; then
    mv "$out.tmp" "$out"
  else
    : > "$out.fail"   # mark failure; keep .err for diagnostics
  fi
}
export -f fetch_one

info "Scanning ${#PROJECTS[@]} project(s) with up to ${WORKERS} parallel workers..."

MANIFEST="$WORKDIR/manifest.tsv"
PROJ_MAP="{"
idx=0
for proj in "${PROJECTS[@]}"; do
  fname="$(printf 'p%05d.json' "$idx")"
  printf '%s\t%s/%s\n' "$proj" "$WORKDIR" "$fname" >> "$MANIFEST"
  [[ "$idx" -gt 0 ]] && PROJ_MAP+=","
  PROJ_MAP+="$(printf '"%s":"%s"' "$fname" "$proj")"
  idx=$((idx + 1))
done
PROJ_MAP+="}"
export PROJ_MAP

xargs -P "$WORKERS" -I{} -d '\n' bash -c 'IFS=$'"'"'\t'"'"' read -r p o <<< "$1"; fetch_one "$p" "$o"' _ {} < "$MANIFEST"

# Report any failures (don't abort the whole run for one bad project).
for f in "$WORKDIR"/*.fail; do
  [[ -e "$f" ]] || continue
  base="${f%.fail}"
  err "Failed to list instances for a project (see ${base}.err). Skipping it."
done

# --- aggregate + classify in a single python pass --------------------------
python3 -c '
import json, os, sys, glob

SHOW_ALL = sys.argv[1] == "true"
AS_JSON  = sys.argv[2] == "true"
workdir  = sys.argv[3]
CSV_PATH = sys.argv[4] if len(sys.argv) > 4 else ""

def _write_csv(rows, path):
    if not path:
        return
    import csv as _c, json as _j
    keys = []
    for r in rows:
        for k in r:
            if k not in keys:
                keys.append(k)
    with open(path, "w", newline="") as fh:
        w = _c.DictWriter(fh, fieldnames=keys, extrasaction="ignore")
        w.writeheader()
        for r in rows:
            w.writerow({k: (_j.dumps(v) if isinstance(v, (list, dict)) else v) for k, v in r.items()})
    sys.stderr.write("CSV written: %s (%d row(s))\n" % (path, len(rows)))

# Map temp file -> project id (from the index manifest passed via env).
proj_by_file = json.loads(os.environ.get("PROJ_MAP", "{}"))

instances = []
for path in sorted(glob.glob(os.path.join(workdir, "p*.json"))):
    proj = proj_by_file.get(os.path.basename(path), "?")
    try:
        with open(path) as fh:
            data = json.load(fh)
    except Exception:
        continue
    for inst in data:
        inst["_project"] = proj
        instances.append(inst)

# Intel family -> equivalent AMD family (same vCPU/memory shape).
INTEL_TO_AMD = {"n1": "n2d", "n2": "n2d", "c2": "c2d", "c3": "c3d"}
# Already-AMD families (treated as optimized).
AMD_FAMILIES = {"n2d", "c2d", "c3d", "t2d"}
# Intel families with no cost-effective AMD equivalent (memory/accelerator/etc.
# and e2, which is already the cost-optimized flexible family).
NO_AMD_INTEL = {"e2", "m1", "m2", "m3", "a2", "a3", "g2", "c4", "h3", "z3", "x4"}

def basename(url):
    return url.rsplit("/", 1)[-1] if url else ""

def vendor_from_platform(cpu):
    c = (cpu or "").strip().lower()
    if c.startswith("intel"):
        return "Intel"
    if c.startswith("amd"):
        return "AMD"
    if "ampere" in c or "arm" in c:
        return "Arm"
    return "Unknown"

def is_mig_managed(inst):
    for item in (inst.get("metadata", {}) or {}).get("items", []) or []:
        if item.get("key") == "created-by" and "instanceGroupManagers" in (item.get("value") or ""):
            return True
    return False

rows = []
counts = {
    "INTEL_STANDALONE_ELIGIBLE": 0, "INTEL_MIG_ELIGIBLE": 0,
    "INTEL_NO_AMD_EQUIVALENT": 0, "ALREADY_OPTIMIZED": 0
}

for inst in instances:
    name   = inst.get("name", "")
    zone   = basename(inst.get("zone"))
    mtype  = basename(inst.get("machineType"))
    cpu    = inst.get("cpuPlatform", "")
    status = inst.get("status", "")
    family = mtype.split("-", 1)[0] if mtype else ""
    managed = is_mig_managed(inst)
    vendor = vendor_from_platform(cpu)

    # Fall back to family when platform is blank (e.g. TERMINATED VMs).
    if vendor == "Unknown":
        if family in AMD_FAMILIES:
            vendor = "AMD"
        elif family in INTEL_TO_AMD or family in NO_AMD_INTEL:
            vendor = "Intel"

    recommended = ""
    if vendor == "Intel" and family in INTEL_TO_AMD:
        parts = mtype.split("-")
        parts[0] = INTEL_TO_AMD[family]
        recommended = "-".join(parts)
        reason = "INTEL_MIG_ELIGIBLE" if managed else "INTEL_STANDALONE_ELIGIBLE"
    elif vendor == "Intel":
        reason = "INTEL_NO_AMD_EQUIVALENT"
    else:
        reason = "ALREADY_OPTIMIZED"   # AMD / Arm / unknown-non-Intel

    counts[reason] = counts.get(reason, 0) + 1
    if reason == "ALREADY_OPTIMIZED" and not SHOW_ALL:
        continue

    rows.append({
        "project": inst.get("_project", "?"),
        "name": name, "zone": zone, "machineType": mtype,
        "cpuPlatform": cpu or "-", "vendor": vendor,
        "managed": "MIG" if managed else "standalone",
        "status": status, "recommendedType": recommended or "-",
        "reason": reason,
    })

# Eligible first, then no-equivalent, then optimized; stable by project+name.
order = {"INTEL_STANDALONE_ELIGIBLE": 0, "INTEL_MIG_ELIGIBLE": 1,
         "INTEL_NO_AMD_EQUIVALENT": 2, "ALREADY_OPTIMIZED": 3}
rows.sort(key=lambda r: (order.get(r["reason"], 9), r["project"], r["name"]))

def print_table(rows, columns):
    """Print a table sized to its content so no value is ever truncated."""
    headers = [h for h, _ in columns]
    keys    = [k for _, k in columns]
    widths  = [len(h) for h in headers]
    cells   = []
    for r in rows:
        row = [str(r.get(k, "")) for k in keys]
        cells.append(row)
        for i, v in enumerate(row):
            if len(v) > widths[i]:
                widths[i] = len(v)
    # Last column is not padded, avoiding trailing whitespace.
    def fmt(values):
        out = [values[i].ljust(widths[i]) for i in range(len(values) - 1)]
        out.append(values[-1])
        return " ".join(out)
    print("")
    print(fmt(headers))
    for row in cells:
        print(fmt(row))

COLUMNS = [
    ("PROJECT", "project"),
    ("NAME", "name"),
    ("ZONE", "zone"),
    ("MACHINE_TYPE", "machineType"),
    ("CPU_PLATFORM", "cpuPlatform"),
    ("MANAGED", "managed"),
    ("STATUS", "status"),
    ("RECOMMENDED", "recommendedType"),
    ("REASON", "reason"),
]

if AS_JSON:
    print(json.dumps(rows, indent=2))
else:
    print_table(rows, COLUMNS)

elig = counts["INTEL_STANDALONE_ELIGIBLE"] + counts["INTEL_MIG_ELIGIBLE"]
sys.stderr.write(
    "\nSummary: %d eligible (%d standalone, %d MIG), %d no-AMD-equivalent, %d already-optimized.\n"
    % (elig, counts["INTEL_STANDALONE_ELIGIBLE"], counts["INTEL_MIG_ELIGIBLE"],
       counts["INTEL_NO_AMD_EQUIVALENT"], counts["ALREADY_OPTIMIZED"]))

_write_csv(rows, CSV_PATH)
' "$SHOW_ALL" "$OUTPUT_JSON" "$WORKDIR" "$CSV_FILE"

info ""
info "Note: read-only. Standalone = stop, change machine type, start."
info "MIG = new template with the AMD type + zero-downtime rolling update."

exit 0

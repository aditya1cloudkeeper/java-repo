#!/usr/bin/env bash
# Runner : execute every recommendation validation script in parallel
#
# What this does:
#   1. Discovers the validation scripts in this directory (any script that
#      drives gcp_reco_lib / aws_reco_lib through run_detection, plus the
#      Intel -> AMD script, which has its own CLI).
#   2. Resolves the scope to a concrete project list once. Every GCP
#      recommendation is evaluated per project, so -o / -f are expanded here
#      with a single walk instead of being re-walked by each of ~28 scripts,
#      and every script then sees the same list.
#   3. Runs them concurrently, JOBS at a time, each with its own -c CSV path.
#   4. Collects everything under an output directory:
#
#        output/<run-id>/projects.txt                 the resolved project list
#        output/<run-id>/csv/<recommendation>.csv     one CSV per script
#        output/<run-id>/tables/<recommendation>.md   the stdout table
#        output/<run-id>/logs/<recommendation>.log    the stderr progress log
#        output/<run-id>/all_gcp_recommendations.csv  every GCP row, merged
#        output/<run-id>/all_aws_recommendations.csv  every AWS row, merged
#        output/<run-id>/summary.csv                  per-script status
#
#   The merged CSVs carry one extra leading column, "recommendation", so rows
#   from different scripts stay attributable. Scripts whose CSV layout matches
#   neither the 7-column GCP nor the 6-column AWS layout are left as their own
#   CSV and flagged in summary.csv.
#
#   Read-only, like the scripts it calls. It only ever writes into OUTPUT_DIR.
#
# Usage: run_all_validations.sh (-p PROJECTS | -o ORG_ID | -f FOLDER_ID | -L FILE)
#        [options]
#        run_all_validations.sh -I       # pick a script and a project file
#        run_all_validations.sh          # same, no arguments means interactive
#
# Interactive mode (-I, or no arguments at all) asks three things: which script
# to run (one, several, or all), which file holds the project IDs, and the
# lookback window. Everything else keeps its default. Prompts go to stderr, so
# DIR=$(./run_all_validations.sh -I) still captures just the run directory.
#
# One script over many projects is sharded: the project list is split across
# JOBS invocations that run in parallel, instead of one invocation walking every
# project in turn. Their CSVs are concatenated back into a single per-script CSV,
# so the output layout does not change. Sharding applies only to project-based
# scopes (-p / -L); with -o / -f the script keeps its own scope flag so the
# Organization ID column stays free.
#
# Options:
#   -p PROJECTS     one project, or several as a comma-separated list
#   -o ORG_ID       evaluate every ACTIVE project under an organization
#   -f FOLDER_ID    evaluate every ACTIVE project under a folder
#   -L FILE         read project IDs from FILE, one per line (# comments ok)
#   -O OUTPUT_DIR   root output directory (default: ./output)
#   -J JOBS         how many scripts to run at once (default 4)
#   -d DAYS         lookback window and age threshold in days (default 30)
#   -n ORG_NAME     render the Organization ID cell as "ORG_NAME (ORG_ID)"
#   -P PRICING_FILE pricing table passed to every script for Potential Savings
#   -i SA_EMAIL     impersonate this service account for every gcloud call
#   -F              render Region using friendly location names
#   -v              echo each gcloud/aws invocation into the per-script log
#   -s LIST         only run scripts matching these comma-separated substrings
#   -x LIST         skip scripts matching these comma-separated substrings
#   -T SECONDS      per-script timeout, 0 disables (default 0)
#   -a              also run the AWS scripts (needs the aws CLI + credentials)
#   -r REGIONS      AWS regions, comma-separated (default: discovered)
#   -U PROFILE      AWS named profile
#   -l              list the scripts that would run, then exit
#   -I              interactive: prompt for the script, project file and window
#   -h              print this header and exit
#
# Notes:
#   * -J above ~6 against a large org can hit Cloud Monitoring and Compute API
#     read quotas. Every script already loops projects serially inside itself,
#     so the effective concurrency is JOBS x (API calls per script).
#   * With -o / -f the scripts still receive that flag, not the expanded list,
#     because it lets them fill the Organization ID column without a
#     get-ancestors call per project. The resolved list is what gates the run
#     and what validate_intel_to_amd.sh (which only takes projects) is fed.
#   * A script that fails does not stop the run; its exit code lands in
#     summary.csv and its log is kept.
#
# Exit codes: 0 every script succeeded, 1 argument or dependency failure,
#             3 the run completed but at least one script failed
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SELF="$(basename -- "${BASH_SOURCE[0]}")"

for arg in "$@"; do
  if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
    awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "${BASH_SOURCE[0]}"
    exit 0
  fi
done

PROJECTS="" ORG_ID="" FOLDER_ID="" PROJECT_FILE=""
OUTPUT_ROOT="$SCRIPT_DIR/output"
JOBS=4 DAYS="" ORG_NAME="" PRICING_FILE="" IMPERSONATE=""
FRIENDLY=false VERBOSE=false
INCLUDE="" EXCLUDE="" TIMEOUT=0
RUN_AWS=false AWS_REGIONS="" AWS_PROFILE_NAME=""
LIST_ONLY=false INTERACTIVE=false
[[ $# -eq 0 ]] && INTERACTIVE=true

# Reports rather than recommendations: correct to run, but one row per
# instance per day, so they are out of the default set.
DEFAULT_EXCLUDE=("show_vm_memory_states.sh")

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*" >&2; }

while getopts ":p:o:f:L:O:J:d:n:P:i:s:x:T:r:U:FvalIh" opt; do
  case "$opt" in
    p) PROJECTS="$OPTARG" ;;
    o) ORG_ID="$OPTARG" ;;
    f) FOLDER_ID="$OPTARG" ;;
    L) PROJECT_FILE="$OPTARG" ;;
    O) OUTPUT_ROOT="$OPTARG" ;;
    J) JOBS="$OPTARG" ;;
    d) DAYS="$OPTARG" ;;
    n) ORG_NAME="$OPTARG" ;;
    P) PRICING_FILE="$OPTARG" ;;
    i) IMPERSONATE="$OPTARG" ;;
    s) INCLUDE="$OPTARG" ;;
    x) EXCLUDE="$OPTARG" ;;
    T) TIMEOUT="$OPTARG" ;;
    r) AWS_REGIONS="$OPTARG" ;;
    U) AWS_PROFILE_NAME="$OPTARG" ;;
    F) FRIENDLY=true ;;
    v) VERBOSE=true ;;
    a) RUN_AWS=true ;;
    l) LIST_ONLY=true ;;
    I) INTERACTIVE=true ;;
    :) die "Option -$OPTARG requires an argument." ;;
    \?) die "Unknown option: -$OPTARG (use -h)" ;;
  esac
done
shift $((OPTIND - 1))
[[ $# -eq 0 ]] || die "Unexpected argument: $1"

scope_count=0
[[ -n "$PROJECTS" ]] && scope_count=$((scope_count + 1))
[[ -n "$ORG_ID" ]] && scope_count=$((scope_count + 1))
[[ -n "$FOLDER_ID" ]] && scope_count=$((scope_count + 1))
[[ -n "$PROJECT_FILE" ]] && scope_count=$((scope_count + 1))

[[ $scope_count -le 1 ]] || die "-p, -o, -f, and -L are mutually exclusive"
# The "exactly one scope" requirement is enforced after interactive setup, which
# is allowed to supply it.
if ! $LIST_ONLY && ! $INTERACTIVE; then
  [[ $scope_count -eq 1 ]] || die "exactly one of -p, -o, -f, or -L is required"
fi

[[ "$JOBS" =~ ^[0-9]+$ && "$JOBS" -gt 0 ]] || die "JOBS (-J) must be a positive integer"
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || die "TIMEOUT (-T) must be a non-negative integer"
if [[ -n "$DAYS" ]]; then
  [[ "$DAYS" =~ ^[0-9]+$ && "$DAYS" -gt 0 ]] || die "DAYS (-d) must be a positive integer"
fi

command -v python3 >/dev/null 2>&1 || die "python3 not found on PATH"
if [[ -n "$PRICING_FILE" ]]; then
  [[ -f "$PRICING_FILE" ]] || die "pricing file not found: $PRICING_FILE"
  PRICING_FILE="$(cd -- "$(dirname -- "$PRICING_FILE")" && pwd)/$(basename -- "$PRICING_FILE")"
fi

# --- script discovery ------------------------------------------------------
matches_list() {
  local name="$1" list="$2" token
  [[ -z "$list" ]] && return 1
  IFS=',' read -ra _tokens <<< "$list"
  for token in "${_tokens[@]}"; do
    token="${token// /}"
    [[ -z "$token" ]] && continue
    [[ "$name" == *"$token"* ]] && return 0
  done
  return 1
}

ALL_FILES=() ALL_CLOUDS=() ALL_STYLES=()
for path in "$SCRIPT_DIR"/*.sh; do
  file="$(basename -- "$path")"
  [[ "$file" == "$SELF" ]] && continue
  if grep -q 'run_detection' "$path" 2>/dev/null; then
    if grep -q 'AWS_RECO_LIB_DIR' "$path" 2>/dev/null; then
      ALL_FILES+=("$file"); ALL_CLOUDS+=("aws"); ALL_STYLES+=("standard")
    else
      ALL_FILES+=("$file"); ALL_CLOUDS+=("gcp"); ALL_STYLES+=("standard")
    fi
  elif [[ "$file" == "validate_intel_to_amd.sh" ]]; then
    ALL_FILES+=("$file"); ALL_CLOUDS+=("gcp"); ALL_STYLES+=("intel")
  fi
done
[[ ${#ALL_FILES[@]} -gt 0 ]] || die "no validation scripts found in $SCRIPT_DIR"

# --- interactive selection --------------------------------------------------
SELECTED=()

ask() {
  # ask VARNAME "prompt" "default"
  local __var="$1" __prompt="$2" __default="$3" __reply=""
  if [[ -n "$__default" ]]; then
    printf '%s [%s]: ' "$__prompt" "$__default" >&2
  else
    printf '%s: ' "$__prompt" >&2
  fi
  IFS= read -r __reply || true
  [[ -z "$__reply" ]] && __reply="$__default"
  printf -v "$__var" '%s' "$__reply"
}

interactive_setup() {
  [[ -t 0 ]] || die "interactive mode needs a terminal; pass -s / -L / -p instead"

  log "Which recommendation do you want to run?"
  log ""
  local idx
  for idx in "${!ALL_FILES[@]}"; do
    local mark=" "
    [[ "${ALL_CLOUDS[$idx]}" == "aws" ]] && mark="*"
    printf '  %2d%s %s\n' "$((idx + 1))" "$mark" "${ALL_FILES[$idx]%.sh}" >&2
  done
  log ""
  log "  * = AWS. Enter a number, several as 1,4,9, a name fragment, or 'all'."

  local choice=""
  while :; do
    ask choice "Script" "all"
    SELECTED=()
    if [[ "$choice" == "all" || "$choice" == "a" ]]; then
      break
    fi
    local token ok=true
    IFS=',' read -ra _tokens <<< "$choice"
    for token in "${_tokens[@]}"; do
      token="${token#"${token%%[![:space:]]*}"}"
      token="${token%"${token##*[![:space:]]}"}"
      [[ -z "$token" ]] && continue
      if [[ "$token" =~ ^[0-9]+$ ]]; then
        if [[ "$token" -ge 1 && "$token" -le ${#ALL_FILES[@]} ]]; then
          SELECTED+=("${ALL_FILES[$((token - 1))]%.sh}")
        else
          log "  no script numbered $token"
          ok=false
        fi
      else
        local hit=false
        for idx in "${!ALL_FILES[@]}"; do
          local name="${ALL_FILES[$idx]%.sh}"
          if [[ "$name" == *"$token"* ]]; then
            SELECTED+=("$name")
            hit=true
          fi
        done
        if ! $hit; then
          log "  nothing matches '$token'"
          ok=false
        fi
      fi
    done
    if $ok && [[ ${#SELECTED[@]} -gt 0 ]]; then
      log "  selected: ${SELECTED[*]}"
      break
    fi
    $ok || log "  try again"
  done

  # An AWS pick implies -a, otherwise it would be filtered straight back out.
  for name in "${SELECTED[@]}"; do
    for idx in "${!ALL_FILES[@]}"; do
      if [[ "${ALL_FILES[$idx]%.sh}" == "$name" && "${ALL_CLOUDS[$idx]}" == "aws" ]]; then
        RUN_AWS=true
      fi
    done
  done

  if [[ $scope_count -eq 0 ]]; then
    local guess=""
    for candidate in "$SCRIPT_DIR/projects.txt" "./projects.txt"; do
      [[ -f "$candidate" ]] && { guess="$candidate"; break; }
    done
    log ""
    log "Which projects? Give a file with one project ID per line, or a"
    log "comma-separated list of IDs."
    local answer=""
    while :; do
      ask answer "Projects" "$guess"
      [[ -z "$answer" ]] && { log "  need a file path or a project list"; continue; }
      if [[ -f "$answer" ]]; then
        PROJECT_FILE="$answer"
        break
      fi
      if [[ "$answer" == *[/.]* && "$answer" != *,* ]]; then
        log "  no such file: $answer"
        continue
      fi
      PROJECTS="$answer"
      break
    done
  fi

  ask DAYS "Lookback window in days" "${DAYS:-30}"
  log ""
}

if $INTERACTIVE && ! $LIST_ONLY; then
  interactive_setup
fi

if [[ -n "$PROJECT_FILE" ]]; then
  [[ -f "$PROJECT_FILE" ]] || die "project file not found: $PROJECT_FILE"
  _from_file=()
  declare -A _seen_file=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line//[[:space:]]/}"
    [[ -z "$line" ]] && continue
    [[ -n "${_seen_file[$line]:-}" ]] && continue
    _seen_file["$line"]=1
    _from_file+=("$line")
  done < "$PROJECT_FILE"
  [[ ${#_from_file[@]} -gt 0 ]] || die "no project IDs found in $PROJECT_FILE"
  PROJECTS="$(IFS=,; echo "${_from_file[*]}")"
  scope_count=1
fi

if ! $LIST_ONLY; then
  [[ -n "$PROJECTS$ORG_ID$FOLDER_ID" ]] || die "exactly one of -p, -o, -f, or -L is required"
fi
if [[ -n "$DAYS" ]]; then
  [[ "$DAYS" =~ ^[0-9]+$ && "$DAYS" -gt 0 ]] || die "DAYS (-d) must be a positive integer"
fi

# --- apply the selection ----------------------------------------------------
SCRIPTS=() CLOUDS=() STYLES=()
for idx in "${!ALL_FILES[@]}"; do
  file="${ALL_FILES[$idx]}"
  cloud="${ALL_CLOUDS[$idx]}"
  style="${ALL_STYLES[$idx]}"
  name="${file%.sh}"

  if [[ "$cloud" == "aws" ]] && ! $RUN_AWS; then
    continue
  fi

  if [[ ${#SELECTED[@]} -gt 0 ]]; then
    keep=false
    for chosen in "${SELECTED[@]}"; do
      [[ "$name" == "$chosen" ]] && keep=true
    done
    $keep || continue
  elif [[ -n "$INCLUDE" ]]; then
    matches_list "$name" "$INCLUDE" || continue
  else
    keep=true
    for skip in "${DEFAULT_EXCLUDE[@]}"; do
      [[ "$file" == "$skip" ]] && keep=false
    done
    $keep || continue
  fi

  matches_list "$name" "$EXCLUDE" && continue
  SCRIPTS+=("$file"); CLOUDS+=("$cloud"); STYLES+=("$style")
done

[[ ${#SCRIPTS[@]} -gt 0 ]] || die "no scripts selected (check -s / -x)"

if $LIST_ONLY; then
  printf '%-52s %-6s %s\n' "SCRIPT" "CLOUD" "CLI"
  for idx in "${!SCRIPTS[@]}"; do
    printf '%-52s %-6s %s\n' "${SCRIPTS[$idx]}" "${CLOUDS[$idx]}" "${STYLES[$idx]}"
  done
  printf '\n%d script(s) selected.\n' "${#SCRIPTS[@]}"
  exit 0
fi

if $RUN_AWS; then
  command -v aws >/dev/null 2>&1 || die "-a given but the aws CLI is not on PATH"
fi
if [[ " ${CLOUDS[*]} " == *" gcp "* ]]; then
  command -v gcloud >/dev/null 2>&1 || die "gcloud CLI not found on PATH"
fi

# --- output layout ---------------------------------------------------------
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$OUTPUT_ROOT/$RUN_ID"
CSV_DIR="$RUN_DIR/csv"
TABLE_DIR="$RUN_DIR/tables"
LOG_DIR="$RUN_DIR/logs"
STATUS_DIR="$RUN_DIR/.status"
mkdir -p "$CSV_DIR" "$TABLE_DIR" "$LOG_DIR" "$STATUS_DIR" || die "cannot create $RUN_DIR"

# A run directory holding nothing but projects.txt is removed again if the
# scope cannot be resolved, so a failed start leaves no empty report behind.
die_unstarted() {
  if [[ -n "${RUN_ID:-}" && "$RUN_DIR" == *"$RUN_ID" ]]; then
    rm -rf "$RUN_DIR"
  fi
  die "$@"
}

SCOPE_DESC=""
[[ -n "$ORG_ID" ]] && SCOPE_DESC="organization=$ORG_ID"
[[ -n "$FOLDER_ID" ]] && SCOPE_DESC="folder=$FOLDER_ID"
if [[ -n "$PROJECTS" ]]; then
  IFS=',' read -ra _scope_items <<< "$PROJECTS"
  if [[ ${#_scope_items[@]} -gt 5 ]]; then
    SCOPE_DESC="projects=${#_scope_items[@]} listed (${_scope_items[0]}, ${_scope_items[1]}, ...)"
  else
    SCOPE_DESC="projects=$PROJECTS"
  fi
fi

log "=== Recommendation validation run $RUN_ID ==="
log "Scope: $SCOPE_DESC | Scripts: ${#SCRIPTS[@]} | Parallel jobs: $JOBS"
log "Output: $RUN_DIR"

# --- resolve the scope to projects once ------------------------------------
# Every GCP recommendation is per project. Resolving here means one walk for
# the whole run, a recorded project list, and the same list for every script.
PROJECT_LIST="$RUN_DIR/projects.txt"
PROJECT_COUNT=0

if [[ " ${CLOUDS[*]} " == *" gcp "* ]]; then
  if [[ -n "$ORG_ID" || -n "$FOLDER_ID" ]]; then
    log "Resolving ACTIVE projects under $SCOPE_DESC ..."
  fi
  GCP_RECO_LIB_DIR="$SCRIPT_DIR" R_PROJECTS="$PROJECTS" R_ORG="$ORG_ID" \
  R_FOLDER="$FOLDER_ID" R_IMPERSONATE="$IMPERSONATE" R_VERBOSE="$VERBOSE" \
  python3 - > "$PROJECT_LIST" <<'PYTHON'
import os
import sys
import types

sys.path.insert(0, os.environ["GCP_RECO_LIB_DIR"])

from gcp_reco_lib import GcpError, Gcloud, ScopeResolver


def warn(message):
    sys.stderr.write("WARN  %s\n" % message)


args = types.SimpleNamespace(
    project=os.environ.get("R_PROJECTS") or None,
    organization=os.environ.get("R_ORG") or None,
    folder=os.environ.get("R_FOLDER") or None,
)
gcloud = Gcloud(
    impersonate=os.environ.get("R_IMPERSONATE") or None,
    verbose=os.environ.get("R_VERBOSE") == "true",
)
try:
    projects = ScopeResolver(gcloud, warn).projects(args)
except GcpError as exc:
    sys.stderr.write("scope resolution failed: %s\n" % exc.summary())
    raise SystemExit(1)
except Exception as exc:
    sys.stderr.write("scope resolution failed: %s\n" % exc)
    raise SystemExit(1)

sys.stdout.write("".join("%s\n" % project for project in projects))
PYTHON
  [[ $? -eq 0 ]] || die_unstarted "could not resolve the project list for $SCOPE_DESC"

  PROJECT_COUNT=$(grep -c . "$PROJECT_LIST" || true)
  [[ "$PROJECT_COUNT" -gt 0 ]] || die_unstarted "no ACTIVE projects found for $SCOPE_DESC"
  log "Projects in scope: $PROJECT_COUNT (see projects.txt)"
fi
log ""

# --- work plan --------------------------------------------------------------
# One script over several projects is split into shards so the projects run in
# parallel; anything else runs one job per script. Shards only make sense for a
# project-based scope, since an -o / -f script resolves its own scope and gets
# the Organization ID column for free.
SHARD_DIR="$RUN_DIR/.shards"
JOB_FILES=() JOB_CLOUDS=() JOB_STYLES=() JOB_LABELS=() JOB_PROJECTS=()
SHARDED=false

if [[ ${#SCRIPTS[@]} -eq 1 && "$PROJECT_COUNT" -gt 1 && "$JOBS" -gt 1 && -n "$PROJECTS" ]]; then
  shards=$(( PROJECT_COUNT < JOBS ? PROJECT_COUNT : JOBS ))
  mkdir -p "$SHARD_DIR"
  # Round robin, so a slow project does not pile up at the end of one shard.
  awk -v n="$shards" -v dir="$SHARD_DIR" 'NF { print > sprintf("%s/shard%02d.txt", dir, (NR - 1) % n + 1) }' "$PROJECT_LIST"
  for ((s = 1; s <= shards; s++)); do
    shard_file="$(printf '%s/shard%02d.txt' "$SHARD_DIR" "$s")"
    [[ -s "$shard_file" ]] || continue
    JOB_FILES+=("${SCRIPTS[0]}")
    JOB_CLOUDS+=("${CLOUDS[0]}")
    JOB_STYLES+=("${STYLES[0]}")
    JOB_LABELS+=("$(printf '%s.shard%02d' "${SCRIPTS[0]%.sh}" "$s")")
    JOB_PROJECTS+=("$(paste -sd, "$shard_file")")
  done
  SHARDED=true
  log "Sharding ${SCRIPTS[0]%.sh} across ${#JOB_FILES[@]} parallel job(s), $PROJECT_COUNT project(s)"
  log ""
else
  for idx in "${!SCRIPTS[@]}"; do
    JOB_FILES+=("${SCRIPTS[$idx]}")
    JOB_CLOUDS+=("${CLOUDS[$idx]}")
    JOB_STYLES+=("${STYLES[$idx]}")
    JOB_LABELS+=("${SCRIPTS[$idx]%.sh}")
    JOB_PROJECTS+=("")
  done
fi

run_one() {
  local file="$1" cloud="$2" style="$3" label="$4" shard_projects="$5"
  local csv="$CSV_DIR/$label.csv"
  local table="$TABLE_DIR/$label.md"
  local logfile="$LOG_DIR/$label.log"
  local status="$STATUS_DIR/$label.tsv"
  local -a cmd=("$SCRIPT_DIR/$file")

  if [[ "$style" == "intel" ]]; then
    # Only takes projects, so it gets the list resolved above.
    if [[ -n "$shard_projects" ]]; then
      cmd+=(-p "$shard_projects" -c "$csv")
    else
      cmd+=(-f "$PROJECT_LIST" -c "$csv")
    fi
  elif [[ "$cloud" == "aws" ]]; then
    cmd+=(-c "$csv")
    [[ -n "$DAYS" ]] && cmd+=(-d "$DAYS")
    [[ -n "$PRICING_FILE" ]] && cmd+=(-P "$PRICING_FILE")
    [[ -n "$AWS_REGIONS" ]] && cmd+=(-r "$AWS_REGIONS")
    [[ -n "$AWS_PROFILE_NAME" ]] && cmd+=(-U "$AWS_PROFILE_NAME")
    $VERBOSE && cmd+=(-v)
  else
    if [[ -n "$shard_projects" ]]; then
      cmd+=(-p "$shard_projects")
    else
      [[ -n "$PROJECTS" ]] && cmd+=(-p "$PROJECTS")
      [[ -n "$ORG_ID" ]] && cmd+=(-o "$ORG_ID")
      [[ -n "$FOLDER_ID" ]] && cmd+=(-f "$FOLDER_ID")
    fi
    cmd+=(-c "$csv")
    [[ -n "$DAYS" ]] && cmd+=(-d "$DAYS")
    [[ -n "$ORG_NAME" ]] && cmd+=(-n "$ORG_NAME")
    [[ -n "$PRICING_FILE" ]] && cmd+=(-P "$PRICING_FILE")
    [[ -n "$IMPERSONATE" ]] && cmd+=(-i "$IMPERSONATE")
    $FRIENDLY && cmd+=(-F)
    $VERBOSE && cmd+=(-v)
  fi

  local t0 t1 rc
  t0=$(date +%s)
  if [[ "$TIMEOUT" -gt 0 ]]; then
    timeout -k 10 "$TIMEOUT" "${cmd[@]}" >"$table" 2>"$logfile"
    rc=$?
  else
    "${cmd[@]}" >"$table" 2>"$logfile"
    rc=$?
  fi
  t1=$(date +%s)

  local rows=0
  if [[ -f "$csv" ]]; then
    rows=$(( $(wc -l < "$csv") - 1 ))
    [[ "$rows" -lt 0 ]] && rows=0
  fi

  local savings="N/A"
  local line
  line=$(grep -m1 'Total potential monthly savings:' "$logfile" 2>/dev/null || true)
  [[ -n "$line" ]] && savings="${line#*savings: }"

  local state note=""
  case "$rc" in
    0) state="ok" ;;
    124|137) state="timeout"; note="killed after ${TIMEOUT}s" ;;
    2) state="failed"; note="every target project failed evaluation" ;;
    *) state="failed"; note="exit code $rc" ;;
  esac
  [[ "$state" != "ok" && -z "$note" ]] && note="see logs/$label.log"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$label" "$cloud" "$state" "$((t1 - t0))" "$rows" "$savings" "$note" > "$status"

  if [[ "$state" == "ok" ]]; then
    log "$(printf 'DONE  %-46s %4ds  %4d row(s)  %s' "$label" "$((t1 - t0))" "$rows" "$savings")"
  else
    log "$(printf 'FAIL  %-46s %4ds  %s (%s)' "$label" "$((t1 - t0))" "$state" "$note")"
  fi
  return 0
}

running=0
for idx in "${!JOB_FILES[@]}"; do
  while [[ "$running" -ge "$JOBS" ]]; do
    wait -n 2>/dev/null || true
    running=$((running - 1))
  done
  run_one "${JOB_FILES[$idx]}" "${JOB_CLOUDS[$idx]}" "${JOB_STYLES[$idx]}" \
          "${JOB_LABELS[$idx]}" "${JOB_PROJECTS[$idx]}" &
  running=$((running + 1))
done
wait

log ""
log "Merging CSVs..."

RUN_DIR="$RUN_DIR" CSV_DIR="$CSV_DIR" STATUS_DIR="$STATUS_DIR" \
RUN_ID="$RUN_ID" SCOPE_DESC="$SCOPE_DESC" python3 - <<'PYTHON'
import csv
import os
import re
import sys

run_dir = os.environ["RUN_DIR"]
csv_dir = os.environ["CSV_DIR"]
status_dir = os.environ["STATUS_DIR"]

GCP_HEADER = ["organizationId", "projectId", "resourceId", "region",
              "potentialSavings", "description", "action"]
AWS_HEADER = ["accountId", "resourceId", "region",
              "potentialSavings", "description", "action"]

LAYOUTS = [("all_gcp_recommendations.csv", GCP_HEADER),
           ("all_aws_recommendations.csv", AWS_HEADER)]

SHARD_RE = re.compile(r"\.shard\d+$")
FIELD_NAMES = ("recommendation", "cloud", "status", "durationSeconds",
               "rows", "totalPotentialMonthlySavings", "note")

STATUS_RANK = {"ok": 0, "skipped": 1, "timeout": 2, "failed": 3}


def base_name(label):
    return SHARD_RE.sub("", label)


def money(text):
    try:
        return float((text or "").replace("$", "").replace(",", "").strip())
    except ValueError:
        return None


raw = []
for entry in sorted(os.listdir(status_dir)):
    if not entry.endswith(".tsv"):
        continue
    with open(os.path.join(status_dir, entry), encoding="utf-8") as handle:
        line = handle.read().rstrip("\n")
    if not line:
        continue
    parts = line.split("\t")
    parts += [""] * (7 - len(parts))
    raw.append(dict(zip(FIELD_NAMES, parts[:7])))

# Shards of one script collapse into a single summary row: worst status wins,
# duration is the slowest shard (they ran in parallel), rows and savings add up.
grouped = {}
order = []
for item in raw:
    key = base_name(item["recommendation"])
    if key not in grouped:
        grouped[key] = []
        order.append(key)
    grouped[key].append(item)

statuses = []
for key in order:
    items = grouped[key]
    if len(items) == 1 and items[0]["recommendation"] == key:
        statuses.append(items[0])
        continue
    worst = max(items, key=lambda i: STATUS_RANK.get(i["status"], 9))
    amounts = [money(i["totalPotentialMonthlySavings"]) for i in items]
    total = "N/A"
    if amounts and all(a is not None for a in amounts):
        total = "$%.2f" % sum(amounts)
    notes = sorted({i["note"] for i in items if i["note"]})
    note = "; ".join(notes)
    shard_note = "%d shard(s), per-shard logs kept" % len(items)
    statuses.append({
        "recommendation": key,
        "cloud": items[0]["cloud"],
        "status": worst["status"],
        "durationSeconds": str(max(int(i["durationSeconds"] or 0)
                                   for i in items if (i["durationSeconds"] or "0").isdigit())),
        "rows": str(sum(int(i["rows"] or 0) for i in items)),
        "totalPotentialMonthlySavings": total,
        "note": ("%s; %s" % (note, shard_note)) if note else shard_note,
    })

# Shard CSVs are concatenated back into one CSV per script, so the output
# layout is identical whether or not the run was sharded.
shard_groups = {}
for entry in sorted(os.listdir(csv_dir)):
    if not entry.endswith(".csv"):
        continue
    label = entry[:-4]
    key = base_name(label)
    if key != label:
        shard_groups.setdefault(key, []).append(entry)

for key, entries in shard_groups.items():
    header = None
    body = []
    for entry in entries:
        path = os.path.join(csv_dir, entry)
        with open(path, newline="", encoding="utf-8") as handle:
            rows = list(csv.reader(handle))
        if not rows:
            os.remove(path)
            continue
        if header is None:
            header = rows[0]
        body.extend(rows[1:])
        os.remove(path)
    if header is None:
        continue
    # Shards finish out of order, so restore a deterministic ordering.
    body.sort()
    with open(os.path.join(csv_dir, "%s.csv" % key), "w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(header)
        writer.writerows(body)

merged = {name: [] for name, _ in LAYOUTS}
unmerged = {}

for entry in sorted(os.listdir(csv_dir)):
    if not entry.endswith(".csv"):
        continue
    name = entry[:-4]
    path = os.path.join(csv_dir, entry)
    with open(path, newline="", encoding="utf-8") as handle:
        rows = list(csv.reader(handle))
    if not rows:
        continue
    header, body = rows[0], rows[1:]
    target = None
    for out_name, layout in LAYOUTS:
        if header == layout:
            target = out_name
            break
    if target is None:
        unmerged[name] = ",".join(header[:4]) + ("..." if len(header) > 4 else "")
        continue
    for row in body:
        merged[target].append([name] + row)

written = []
for out_name, layout in LAYOUTS:
    rows = merged[out_name]
    if not rows:
        continue
    out_path = os.path.join(run_dir, out_name)
    with open(out_path, "w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(["recommendation"] + layout)
        writer.writerows(rows)
    written.append((out_name, len(rows)))

with open(os.path.join(run_dir, "summary.csv"), "w", newline="", encoding="utf-8") as handle:
    writer = csv.DictWriter(handle, fieldnames=FIELD_NAMES)
    writer.writeheader()
    for item in statuses:
        if item["recommendation"] in unmerged:
            extra = "non-standard CSV layout (%s), left unmerged" % unmerged[item["recommendation"]]
            item["note"] = ("%s; %s" % (item["note"], extra)).lstrip("; ")
        writer.writerow(item)

for out_name, count in written:
    sys.stderr.write("  %s  (%d row(s))\n" % (out_name, count))
sys.stderr.write("  summary.csv  (%d script(s))\n" % len(statuses))

ok = sum(1 for s in statuses if s["status"] == "ok")
failed = [s for s in statuses if s["status"] not in ("ok", "skipped")]
skipped = [s for s in statuses if s["status"] == "skipped"]
total_rows = sum(int(s["rows"] or 0) for s in statuses)

sys.stderr.write("\nScripts ok: %d | failed: %d | skipped: %d | total rows: %d\n"
                 % (ok, len(failed), len(skipped), total_rows))
for item in failed:
    sys.stderr.write("  FAILED  %s: %s\n" % (item["recommendation"], item["note"]))

raise SystemExit(3 if failed else 0)
PYTHON
MERGE_RC=$?

rm -rf "$STATUS_DIR" "$SHARD_DIR"

log ""
log "Report directory: $RUN_DIR"
printf '%s\n' "$RUN_DIR"

exit "$MERGE_RC"

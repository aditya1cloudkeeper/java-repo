# Recommendation detection scripts

One script per recommendation explainer in `../`. GCP scripts load
`gcp_reco_lib.py` and print the seven-column layout:

`Organization ID | Project ID | Resource ID | Region | Potential Savings | Description | Action`

AWS scripts load `aws_reco_lib.py` and print the six-column AWS layout, which
has an account ID in place of the organization/project pair:

`AWS Account ID | Resource ID | Region | Potential Savings | Description | Action`

The two libraries are independent on purpose, so an AWS change cannot disturb the
GCP scripts. A little generic code (pricing, savings formatting, table
serialization) is duplicated rather than shared.

## Run everything at once

`run_all_validations.sh` runs the whole set in parallel and collects the results
as CSV. It discovers the scripts itself (anything driving `run_detection`, plus
`validate_intel_to_amd.sh`), so adding a new detection script needs no change
here.

Run it with no arguments (or `-I`) and it asks which recommendation to run,
which file holds the project IDs, and the lookback window:

```
$ ./run_all_validations.sh
Which recommendation do you want to run?

   1  cleaner_PD-unattached
   2  cleaner_load-balancer
   ...
  19  validate_intel_to_amd
  29* validate_ebs_gp3_modernization

  * = AWS. Enter a number, several as 1,4,9, a name fragment, or 'all'.
Script [all]: 9
  selected: validate_idle_cloud_dns

Which projects? Give a file with one project ID per line, or a
comma-separated list of IDs.
Projects [./projects.txt]: my-projects.txt
Lookback window in days [30]: 60
```

Picking an AWS script turns on `-a` for you. Prompts go to stderr, so
`DIR=$(./run_all_validations.sh -I)` still captures just the run directory.

Non-interactive usage is unchanged:

```bash
# see what would run
./run_all_validations.sh -l

# whole org, 6 at a time, savings from a rate card
./run_all_validations.sh -o 1062961896330 -n cloudkeeper -P pricing.sample.csv -J 6

# a few projects, GCP + AWS, 20-minute cap per script
./run_all_validations.sh -p proj-a,proj-b -a -U my-aws-profile -T 1200

# projects from a file, one ID per line
./run_all_validations.sh -L my-projects.txt

# just the over-provisioned family
./run_all_validations.sh -p proj-a -s overprovisioned
```

When the run comes down to a single script, the project list is sharded across
`-J` parallel invocations instead of one invocation walking every project in
turn. Their CSVs are concatenated back into one `csv/<script>.csv` and their
summary rows collapse into one, so the output looks the same either way; only
the logs stay per shard (`logs/<script>.shard01.log`). Sharding needs a
project-based scope, `-p` or `-L`. With `-o` / `-f` a single script keeps its own
scope flag, which is cheaper for the Organization ID column.

Scope is project-based, because every recommendation is evaluated per project.
`-p` and `-L` name the projects directly; `-o` and `-f` are expanded to a
project list once, up front, rather than being re-walked by each of the ~28
scripts. The resolved list is saved as `projects.txt` and the run stops before
any script starts if it comes back empty or the walk is denied.

The scripts themselves still receive the `-o` / `-f` flag you passed, not the
expanded list. That is deliberate: given an org ID they fill the Organization ID
column straight from it, whereas a project list costs one `get-ancestors` call
per project per script. `validate_intel_to_amd.sh` is the exception, since it
only understands projects, so it is fed `projects.txt` and no longer sits out
org- and folder-scoped runs.

Output lands in a timestamped directory (`-O` moves the root, default
`./output`):

```
output/<run-id>/all_gcp_recommendations.csv   every GCP row, merged
output/<run-id>/all_aws_recommendations.csv   every AWS row, merged (with -a)
output/<run-id>/summary.csv                   per script: status, rows, savings
output/<run-id>/projects.txt                  the resolved project list
output/<run-id>/csv/<recommendation>.csv      one CSV per script
output/<run-id>/tables/<recommendation>.md    the stdout table
output/<run-id>/logs/<recommendation>.log     the stderr progress log
```

The merged CSVs prepend a `recommendation` column so rows stay attributable.
A script whose CSV layout matches neither the 7-column GCP nor the 6-column AWS
layout keeps its own CSV and is flagged in `summary.csv` instead of being
force-fitted; `validate_intel_to_amd.sh` is the current example. The run
directory path is the only thing written to stdout, so
`DIR=$(./run_all_validations.sh -p x)` works.

| Flag | Meaning |
| :---- | :---- |
| `-p` / `-o` / `-f` | scope, same meaning as the individual scripts, one required |
| `-L FILE` | project IDs from a file, one per line, `#` comments allowed |
| `-O OUTPUT_DIR` | output root, default `./output` |
| `-J JOBS` | scripts running at once, default 4 |
| `-d` `-n` `-P` `-i` `-F` `-v` | forwarded to every GCP script |
| `-s LIST` / `-x LIST` | include / exclude by comma-separated substring |
| `-T SECONDS` | per-script timeout, 0 disables (default) |
| `-a` | also run the AWS scripts |
| `-r REGIONS` / `-U PROFILE` | AWS regions and named profile |
| `-l` | list the selected scripts and exit |
| `-I` | interactive: prompt for the script, project file and window |

Only the flags every script shares are forwarded. Script-specific flags (`-u`,
`-T` on the load balancer, `-K`, `-E`, and so on) are not, so run that script
directly when you need to change one of those.

A failing script does not stop the run: its exit code and log are kept and the
runner exits `3`. Exit `0` means every selected script succeeded, `1` means bad
arguments, an unresolvable scope, or a missing dependency.

`-J` past roughly 6 against a large org starts bumping into Cloud Monitoring and
Compute read quotas, since each script is already looping projects inside itself.
`show_vm_memory_states.sh` is excluded by default because it is a per-instance
per-day report rather than a recommendation; `-s show_vm_memory_states` runs it
anyway.

## AWS

| Script | Recommendation | Source |
| :---- | :---- | :---- |
| `validate_ebs_gp3_modernization.sh` | EC2 EBS volume type modernization | EBS modernization doc |

AWS scripts take a different flag set from the GCP ones: `-r REGIONS` (default:
discover via `describe-regions`), `-d DAYS`, `-e PERIOD` for the CloudWatch
period, `-b BASELINE` for the gp3 baseline IOPS, `-s STATES` for which volume
states to evaluate, `-A ACCOUNT_ID`, `-U PROFILE`, plus the shared
`-P` / `-c` / `-j` / `-v` / `-h`. Use `pricing.aws.sample.csv` for `-P`.

Read-only is enforced the same way: `Aws.assert_read_only` allows only verbs
beginning `describe-`, `get-`, `list-`, `lookup-`, `search-` or `batch-get-`, so
`modify-volume`, `delete-volume`, `detach-volume` and friends are rejected before
a subprocess starts.

## GCP

### Cleaner / Idle

| Script | Recommendation | Source doc |
| :---- | :---- | :---- |
| `validate_stopped_vm_instances.sh` | Stopped VM instances | `IDLE VM Instance.md` |
| `validate_idle_cloud_run_services.sh` | Idle Cloud Run services | `Idle Cloud Run Services _ GCP Cleaner.md` |
| `validate_idle_filestore.sh` | Idle Filestore instances | `Idle Filestore.md` |
| `validate_idle_pd_snapshots.sh` | Idle PD snapshots | `Idle PD Snapshot.md` |
| `validate_idle_cloudsql.sh` | Idle Cloud SQL instances | `Idle SQL.md` |
| `validate_idle_attached_pd.sh` | Idle attached PDs | `Idle attached PD.md` |
| `validate_idle_memorystore_redis.sh` | Idle Memorystore for Redis | `MemoryStore Redis _ GCP Cleaner.md` |
| `validate_orphaned_pd.sh` | Orphaned (unattached) PDs | `idle pd.md` |
| `validate_idle_load_balancer.sh` | Idle load balancers | `Cleaner __ Idle Load Balancer.md` |
| `validate_idle_cloud_dns.sh` | Idle DNS zones | `IDLE Cloud DNS _ GCP-Cleaner.md` |
| `validate_idle_nat_gateway.sh` | Idle NAT gateways | `idle nat gateway.md` |
| `validate_idle_vpn_gateway.sh` | Idle VPN gateways | `IDLE VPN Gateway.md` |
| `validate_idle_app_engine.sh` | Idle App Engine services | `Idle App Engine __ GCP Cleaner.md` |
| `validate_idle_vertex_endpoints.sh` | Idle Vertex AI endpoints / deployed models | `GCP Gemini API Vertex AI Endpoint Cleaner Recommendation.md` |
| `validate_incomplete_multipart_uploads.sh` | Incomplete multipart uploads | `GCP Cleaner __ Multipart uploads.md` |
| `validate_idle_alloydb_backups.sh` | Stale AlloyDB backups | `Cleaner __ AlloyDB Backups.md` |

### Modernization

| Script | Recommendation | Source doc |
| :---- | :---- | :---- |
| `validate_redis_to_valkey.sh` | Memorystore for Redis -> Valkey 7.2 | `Modernization __ Memorystore redis to valkey.md` |
| `validate_intel_to_amd.sh` | Intel -> AMD VM machine types | Intel/AMD modernization doc |

### Over-provisioned

| Script | Recommendation | Source doc |
| :---- | :---- | :---- |
| `validate_overprovisioned_vm_instances.sh` | VM instance right-sizing | `Overprovisioned __ GCP VM Instance.md` |
| `validate_overprovisioned_cloudsql.sh` | Cloud SQL right-sizing | `Overprovisioning_ CloudSQL.md` |
| `validate_cloudsql_zone_optimize.sh` | Cloud SQL regional HA in non-prod | `Overprovisioned __ Cloud SQL Zone Optimize.md` |
| `validate_overprovisioned_cloud_run.sh` | Cloud Run right-sizing | `CloudRun Overprovisioned.md` |
| `validate_overprovisioned_appengine.sh` | App Engine manual scaling | `GCP Overprovisioned __ AppEngine.md` |
| `validate_overprovisioned_pd.sh` | PD provisioned IOPS / throughput | `OverProvisioned _ PD.md` |
| `validate_overprovisioned_filestore.sh` | Filestore capacity / IOPS | `OverProvisioned _ FileStore.md` |
| `validate_overprovisioned_memorystore.sh` | Memorystore for Redis capacity right-sizing | `OverProvisioned _ Memory Store.md` |
| `validate_overprovisioned_alloydb.sh` | AlloyDB instance right-sizing | `Overprovisioned __ GCP AlloyDB.md` |
| `validate_overprovisioned_mig.sh` | Fixed-size MIG right-sizing | `Overprovisioned  __ GCP MIG.md` |

`gcp_reco_lib.py` is the shared library every script loads: scope resolution,
Cloud Monitoring queries, savings lookup, console links, and table rendering.

## Read-only guarantee

These scripts never create, update, or delete anything. That is enforced in
three places, not just by convention:

1. `Gcloud.assert_read_only()` runs before any subprocess is spawned and allows
   only these verbs: `list`, `describe`, `get`, `get-ancestors`,
   `list-instances`, `get-iam-policy`, `print-access-token`. Anything else
   (`delete`, `create`, `patch`, `update`, `stop`, `add-iam-policy-binding`) raises
   `ReadOnlyViolation` and the command is never executed.
2. Every gcloud invocation goes through that single runner. There is no other
   code path that shells out to gcloud.
3. The only HTTP traffic is `GET` against Cloud Monitoring
   `timeSeries.list`; the request method is pinned to `GET`.

Viewer-level roles are enough to run any of them. The only files written are the
ones you ask for with `-c` and stdout.

## Requirements

For GCP: `gcloud` and `python3` on `PATH`, plus an active credential
(`gcloud auth login` or `gcloud auth application-default login`).

For AWS: `aws` and `python3` on `PATH`, plus working credentials (`aws configure`,
`AWS_PROFILE`, or `-U PROFILE`).

Python standard library only, either way. No pip installs.

## Usage

```bash
# one project
./validate_orphaned_pd.sh -p my-test-project-468909

# several specific projects, one merged table
./validate_orphaned_pd.sh -p proj-a,proj-b,proj-c

# whole org, friendly region names, org name in the first column
./validate_stopped_vm_instances.sh -o 1062961896330 -n cloudkeeper -F

# 60-day window, savings from a rate card, CSV alongside the table
./validate_idle_filestore.sh -f 123456789012 -d 60 -P pricing.sample.csv -c out.csv

# JSON instead of Markdown
./validate_idle_cloudsql.sh -p ck-tuner -j
```

### Options (identical on every script)

| Flag | Meaning |
| :---- | :---- |
| `-p PROJECTS` | one project, or several as a comma-separated list |
| `-o ORG_ID` | evaluate every ACTIVE project under an organization |
| `-f FOLDER_ID` | evaluate every ACTIVE project under a folder |
| `-d DAYS` | lookback window and age threshold, default 30 |
| `-u PERCENT` | utilization threshold, over-provisioned scripts only, default 30 |
| `-n ORG_NAME` | render Organization ID as `ORG_NAME (ORG_ID)` |
| `-P PRICING_FILE` | rate card used to fill Potential Savings |
| `-i SA_EMAIL` | impersonate a service account |
| `-c CSV_FILE` | also write the rows to CSV (overwrites) |
| `-j` | print a JSON array instead of the table |
| `-F` | render Region with friendly location names |
| `-v` | echo each gcloud invocation to stderr |
| `-h` | print the script header and exit |

`-p`, `-o`, and `-f` are mutually exclusive and one is required.

A few scripts add one flag of their own; `-h` on each lists them:

| Flag | Script | Meaning |
| :---- | :---- | :---- |
| `-T THRESHOLD` | idle load balancer | idle if totalTraffic <= THRESHOLD, default 0 |
| `-g MIN_GIB` | multipart uploads | minimum abandoned size to report, default 1 GiB |
| `-g MIN_GIB` | GCS storage class | minimum bucket size to report, default 1 GiB |
| `-t THRESHOLDS` | GCS storage class | idle-day ladder as NEARLINE,COLDLINE,ARCHIVE |
| `-R REGIONS` | Vertex endpoints | scan these locations instead of discovering them |
| `-E REGEX` / `-L LIST` | Cloud SQL zone optimize | which projects count as non-production |
| `-K KEYS` | AlloyDB backups | label keys that mark a backup as deliberately retained |
| `-C` `-B` `-S` `-G` | AlloyDB right-sizing | connections per vCPU, cache-hit floor, spill ceiling, replication-lag ceiling |
| `-t TARGET` / `-m MIN` | MIG right-sizing | target utilization for sizing, and the instance-count floor |
| `-s PCT` | Redis to Valkey | Valkey discount versus Redis, percent, default 30 |

The table (or JSON) goes to **stdout**; progress, warnings, and the summary go
to **stderr**, so `./validate_orphaned_pd.sh -p x > report.md` gives you a clean
report.

Exit codes: `0` success, `1` bad arguments or missing dependency, `2` every
target project failed to evaluate.

## Potential Savings

Without `-P` the column is `N/A`. With `-P` the value is the projected monthly
cost using a 730-hour month. See `pricing.sample.csv` for the format and units;
replace the placeholder rates with your own rate card before trusting the
numbers. Resources whose attributes match no rate are reported with `N/A` and a
warning on stderr.

For the over-provisioned family, Potential Savings is the difference between the
current configuration's monthly cost and the recommended one. If either side has
no matching rate the cell is `N/A` rather than a half-computed number.

## Notes per recommendation

- **Stopped VMs** — savings add the machine type and every attached disk.
- **Cloud Run** — two outcomes: idle with warm instances (`minScale` /
  `manualInstanceCount` > 0) versus idle with no compute cost.
- **Filestore** — `ALIGN_RATE` over 60s buckets; buckets under 1.0 op/s are
  treated as noise, per the doc's pseudocode.
- **PD snapshots** — skips auto-created snapshots, snapshots from a schedule
  (source disk has a `resourcePolicy`), and snapshots referenced by a machine
  image.
- **Cloud SQL** — MySQL/SQL Server use `network/connections`, PostgreSQL uses
  `postgresql/num_backends`; idle means peak connections < 10.
- **Attached PDs** — non-boot disks only; a disk shared by several VMs is
  reported once and only if idle on every attachment.
- **Redis** — zero connections, or connections with zero commands.
- **Orphaned PDs** — a `lastAttachTimestamp` newer than the detach time means
  the disk was reattached, so it is not reported.

- **Load balancers** — forwarding rules are classified (L7, L4 classic proxy, L4
  modern proxy, L3 passthrough, UDP) and each class gets its own metric set.
  PSC endpoints, non TCP/UDP protocols and unknown targets are skipped. For
  passthrough LBs `rtt_latencies` separates health-check noise from real flows,
  since probes never complete a handshake.
- **DNS zones** — the NS and SOA records created with every zone are ignored, so
  a zone is idle only when it has no records of its own.
- **NAT / VPN gateways** — idle means both sent and received bytes are zero.
- **App Engine (idle)** — per service, using `http/server/response_count` on the
  `gae_app` resource.
- **App Engine (over-provisioned)** — manual-scaling versions only; B8 is skipped
  because no downgrade is defined for it.
- **Vertex AI** — an endpoint with zero predictions flags all its models; an
  endpoint that is serving flags only models older than the window with zero
  predictions of their own.
- **Redis to Valkey** — one `redis instances list --region -` call per project.
  Non-READY instances and instances already on Valkey are skipped silently; an
  unrecognised version or tier is reported on stderr instead, since that means
  the API grew a value this script does not know. The doc gives no savings
  formula beyond "Valkey is about 30% cheaper", so savings are the Redis monthly
  cost from the rate card times `-s` (default 30%). The doc's worked example uses
  a 720-hour month; this script uses 730 like every other script here, so figures
  run about 1.4% higher than the doc's.
- **GCS storage class** — buckets smaller than `-g` (default 1 GiB) are skipped,
  empty ones included. Tiering a near-empty bucket saves nothing measurable while
  a class change still costs one transition operation per object. The source doc
  sets no floor, so this is a deliberate addition.
- **Multipart uploads** — the `?uploads` listing carries no sizes, so each
  upload's parts are listed to get the byte count. Buckets that already abort
  incomplete uploads via lifecycle are skipped.
- **VM right-sizing** — RUNNING, non-Spot only. Memory needs the Ops Agent; when
  the agent series is missing the script says so and applies the CPU rule alone.
  Candidates never leave the current machine family, so architecture, category
  and OS stay put.
- **Cloud Run right-sizing** — instance-based billing with manual scaling only.
  Autoscaled services are left alone because downsizing can trip the utilization
  target and spawn another instance.
- **AlloyDB backups** — CONTINUOUS backups are skipped: they form the PITR window
  and are governed by cluster retention, not deleted individually. Backups whose
  source cluster is gone are called out in the description.
- **AlloyDB right-sizing** — tiers couple vCPU and memory at a fixed ratio, so
  every move changes both. A candidate is accepted only when the projected
  utilization of both dimensions stays at or below 70% and the target tier can
  still carry the observed peak connection count. Instances at 2 vCPU or fewer
  are out of scope.
- **MIGs** — autoscaled groups are skipped. The group size must be unchanged
  across the whole window, checked with min vs max of `instance_group/size`; a
  group with no size history is skipped rather than assumed stable. The result
  never drops below 2 instances.

When Cloud Monitoring returns no time series at all for a resource, that
resource is skipped with a warning rather than being treated as zero usage. The
load balancer, NAT and VPN scripts are the deliberate exceptions: their source
docs treat an empty response as proof of zero traffic, and the scripts say so in
their headers.

## Known gaps carried over from the docs

Several explainers leave details unresolved. Where that happens the script picks
the documented-looking option and says so in its header, but these are worth a
review before the numbers are published:

- No doc gives a savings formula. Every figure here comes from the rate card you
  supply via `-P`.
- `Idle App Engine __ GCP Cleaner.md` names `http/server/response_count` without
  a full metric type or aggregation; the full type and `ALIGN_SUM` are assumed.
- `OverProvisioned _ FileStore.md` and `OverProvisioned _ PD.md` keep their
  aligner and label details inside screenshots. Filestore uses `ALIGN_MAX` on
  daily buckets and PD uses `ALIGN_RATE` per minute here.
- Two docs ship sample commands with a 7-day or 1-day window against a stated
  30-day spec. The scripts use `-d` (default 30).
- `GCP Overprovisioned __ AppEngine.md` only publishes the B1 memory limit; the
  other instance-class limits in `validate_overprovisioned_appengine.sh` are the
  standard published values and should be confirmed.
- `Overprovisioned __ Cloud SQL Zone Optimize.md` relies on environment
  classification done at onboarding. This script substitutes a project-ID
  pattern (`-E` / `-L`), so confirm the matches are really non-production.
- `Overprovisioned __ GCP AlloyDB.md` names its metrics unqualified
  (`database/cpu/utilization`) and gives no thresholds for the buffer-cache,
  temp-spill or replication-lag gates. The script assumes the
  `alloydb.googleapis.com/instance/...` types and ships defaults for the gates
  (`-B 90`, `-S 0`, `-G 10`). When a gate returns no data the row says the check
  was not verified instead of quietly passing it. The connections-per-vCPU budget
  (`-C`, default 50) is also an assumption, not a documented figure.
- The AlloyDB and MIG docs both include a "Recommendation Age" column that the
  seven-column layout has no slot for; the age is folded into Description.
- `Cleaner __ AlloyDB Backups.md` excludes backups held for compliance, legal
  hold or an in-flight restore. None of that is readable through the API, so the
  script only skips backups carrying a retention label (`-K`). Confirm ownership
  before deleting anything it lists.
- The EBS doc compares raw `VolumeReadOps` counts against 3000 IOPS. Those units
  do not match: `VolumeReadOps` is a count of operations per period, so a count of
  3000 over an hour is under 1 IOPS. The script divides by the period to get a
  rate before comparing, which is what the 3000 threshold means.
- The EBS doc's Case 1 triggers on volume type alone, while its Action text also
  mentions IOPS fitting the gp3 baseline. The script follows the stated trigger
  (all gp2 volumes are reported) but computes observed IOPS anyway and, when the
  peak exceeds the baseline, says how many IOPS to provision on gp3 so the move
  is not a silent performance regression.
- `maxIopsUsage` is the doc's `max(read) + max(write)`, i.e. the sum of two
  independent maxima. That is a conservative upper bound, not the true
  timestamp-aligned peak, so it errs toward not recommending a change.
- io2 provisioned-IOPS pricing is tiered; `pricing.aws.sample.csv` carries only
  the first tier, so io1 -> io2 savings read low for high-IOPS volumes.

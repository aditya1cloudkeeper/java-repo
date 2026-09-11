"""Shared library for AWS cost-recommendation detection scripts.

The AWS Recommendation Layout has six columns, not the seven used on the GCP
side (there is no Organization ID / Project ID pair, just an AWS Account ID):

``AWS Account ID | Resource ID | Region | Potential Savings | Description | Action``

Responsibilities
----------------
* CLI parsing shared by the AWS detection scripts
* Aws            -> read-only ``aws`` CLI runner with a verb allowlist
* Region_Resolver-> expand the requested regions, or discover them from EC2
* Metric_Client  -> CloudWatch ``get-metric-statistics`` with datapoint chunking
* Savings_Calculator / Pricing_Table
* Row_Serializer / Row_Parser for the six-column layout

Only the Python standard library and the ``aws`` CLI are used. Every AWS call is
a read-only operation (``describe-*``, ``get-*``, ``list-*``).

This is deliberately separate from ``gcp_reco_lib.py`` so the two clouds stay
independent; a little generic code (pricing, savings formatting) is duplicated
rather than coupling the verified GCP scripts to AWS changes.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime, timedelta, timezone

HOURS_PER_MONTH = 730
NO_DATA = "NO_DATA"
NOT_AVAILABLE = "N/A"

# CloudWatch returns at most this many datapoints per get-metric-statistics call.
MAX_DATAPOINTS = 1440

FIELDS = (
    "accountId",
    "resourceId",
    "region",
    "potentialSavings",
    "description",
    "action",
)

HEADERS = (
    "AWS Account ID",
    "Resource ID",
    "Region",
    "Potential Savings",
    "Description",
    "Action",
)

ALIGNMENT_ROW = "| " + " | ".join([":----"] * len(HEADERS)) + " |"

_CELL_SPLIT_RE = re.compile(r"(?<!\\)\|")

EXIT_OK = 0
EXIT_USAGE = 1
EXIT_ALL_REGIONS_FAILED = 2


# --------------------------------------------------------------------------- #
# Recommendation_Row + Row_Serializer + Row_Parser
# --------------------------------------------------------------------------- #


class MalformedRow(Exception):
    code = "MALFORMED_ROW"

    def __init__(self, index, cell_count):
        super().__init__("MALFORMED_ROW at row %d (%d cells)" % (index, cell_count))
        self.index = index
        self.cell_count = cell_count


class Row(object):
    __slots__ = FIELDS + ("_link", "_savings_amount")

    def __init__(
        self,
        accountId=NOT_AVAILABLE,
        resourceId="",
        region="",
        potentialSavings=NOT_AVAILABLE,
        description="",
        action="",
        link=None,
        savings_amount=None,
    ):
        self.accountId = accountId
        self.resourceId = resourceId
        self.region = region
        self.potentialSavings = potentialSavings
        self.description = description
        self.action = action
        self._link = link
        self._savings_amount = savings_amount

    def as_dict(self):
        return dict((name, getattr(self, name)) for name in FIELDS)

    def values(self):
        return tuple(getattr(self, name) for name in FIELDS)

    @property
    def savings_amount(self):
        return self._savings_amount

    @property
    def link(self):
        return self._link

    def sort_key(self):
        return (self.region, self.resourceId)

    def __eq__(self, other):
        return isinstance(other, Row) and self.values() == other.values()

    def __repr__(self):
        return "Row(%r)" % (self.values(),)


def _escape_cell(value):
    text = "" if value is None else str(value)
    text = text.replace("|", r"\|")
    text = re.sub(r"[\r\n]+", " ", text)
    return text.strip()


def serialize_rows(rows):
    lines = ["| " + " | ".join(HEADERS) + " |", ALIGNMENT_ROW]
    for row in rows:
        resource = row.resourceId
        if row.link:
            resource = "[%s](%s)" % (row.resourceId, row.link)
        cells = [
            row.accountId,
            resource,
            row.region,
            row.potentialSavings,
            row.description,
            row.action,
        ]
        lines.append("| " + " | ".join(_escape_cell(cell) for cell in cells) + " |")
    return "\n".join(lines)


def parse_table(text):
    rows = []
    index = 0
    for raw in text.splitlines():
        line = raw.strip()
        if not line.startswith("|"):
            continue
        index += 1
        body = line[1:-1] if line.endswith("|") and len(line) > 1 else line[1:]
        cells = [cell.strip() for cell in _CELL_SPLIT_RE.split(body)]
        if index == 1 and [c.lower() for c in cells] == [h.lower() for h in HEADERS]:
            continue
        if set("".join(cells)) <= set(":- "):
            continue
        if len(cells) != len(HEADERS):
            raise MalformedRow(index, len(cells))
        rows.append(Row(*[cell.replace(r"\|", "|") for cell in cells]))
    return rows


def console_url(kind, region, resource_id):
    """AWS console deep link, or None when the type has no mapping."""
    if kind == "ebs-volume":
        return (
            "https://console.aws.amazon.com/ec2/home?region=%s#VolumeDetails:volumeId=%s"
            % (region, resource_id)
        )
    if kind == "ec2-instance":
        return (
            "https://console.aws.amazon.com/ec2/home?region=%s#InstanceDetails:instanceId=%s"
            % (region, resource_id)
        )
    return None


# --------------------------------------------------------------------------- #
# Time helpers
# --------------------------------------------------------------------------- #


def parse_ts(value):
    if not value:
        return None
    text = str(value).strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    text = re.sub(r"\.(\d{6})\d+", r".\1", text)
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def iso(moment):
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def elapsed_days(start, end):
    if start is None or end is None:
        return 0.0
    return (end - start).total_seconds() / 86400.0


# --------------------------------------------------------------------------- #
# Read-only aws CLI runner
# --------------------------------------------------------------------------- #


class ReadOnlyViolation(Exception):
    """Raised when a caller tries to run an aws verb that could mutate state."""


class AwsError(Exception):
    def __init__(self, kind, detail):
        super().__init__(detail)
        self.kind = kind  # access_denied | not_found | opt_in_required | other
        self.detail = detail

    def summary(self):
        if self.kind == "access_denied":
            return "access denied"
        if self.kind == "opt_in_required":
            return "region not enabled for this account"
        if self.kind == "not_found":
            return "not found"
        return self.detail


READ_ONLY_PREFIXES = ("describe-", "get-", "list-", "lookup-", "search-", "batch-get-")


def _classify(stderr):
    text = " ".join((stderr or "").split())[:400]
    lowered = text.lower()
    if "accessdenied" in lowered or "not authorized" in lowered or "unauthorizedoperation" in lowered:
        return AwsError("access_denied", text)
    if "optinrequired" in lowered or "not authorized for this service" in lowered:
        return AwsError("opt_in_required", text)
    if "notfound" in lowered or "does not exist" in lowered or "invalidvolume.notfound" in lowered:
        return AwsError("not_found", text)
    return AwsError("other", text or "aws invocation failed")


class Aws(object):
    """Read-only aws CLI runner.

    Only verbs whose name starts with a read-only prefix may run. Anything else
    raises :class:`ReadOnlyViolation` before a subprocess is spawned, so a
    detection script cannot create, modify, or delete an AWS resource.
    """

    def __init__(self, profile=None, verbose=False):
        self.profile = profile
        self.verbose = verbose

    @classmethod
    def assert_read_only(cls, args):
        leading = []
        for token in args:
            if str(token).startswith("-"):
                break
            leading.append(str(token))
        # Shape is "<service> <verb> [args]"; the verb is the second token.
        verb = leading[1] if len(leading) > 1 else ""
        if not verb.startswith(READ_ONLY_PREFIXES):
            raise ReadOnlyViolation(
                "refusing to run non read-only aws command: %s" % " ".join(leading)
            )

    def run(self, args, region=None, allow_failure=False):
        self.assert_read_only(args)
        cmd = ["aws"] + list(args) + ["--output", "json"]
        if region:
            cmd += ["--region", region]
        if self.profile:
            cmd += ["--profile", self.profile]
        if self.verbose:
            sys.stderr.write("  + %s\n" % " ".join(cmd))
        completed = subprocess.run(cmd, capture_output=True, text=True)
        if completed.returncode != 0:
            if allow_failure:
                return None
            raise _classify(completed.stderr)
        payload = completed.stdout.strip()
        if not payload:
            return {}
        try:
            return json.loads(payload)
        except ValueError as exc:
            raise AwsError("other", "unparseable aws JSON output: %s" % exc)

    def account_id(self):
        try:
            identity = self.run(["sts", "get-caller-identity"])
        except AwsError:
            return None
        return (identity or {}).get("Account")


# --------------------------------------------------------------------------- #
# Region resolution
# --------------------------------------------------------------------------- #


def resolve_regions(aws, requested, warn):
    if requested:
        return [item.strip() for item in requested.split(",") if item.strip()]
    try:
        payload = aws.run(["ec2", "describe-regions"], region="us-east-1")
    except AwsError as exc:
        warn("cannot discover regions: %s" % exc.summary())
        return []
    return sorted(
        entry.get("RegionName")
        for entry in (payload or {}).get("Regions", []) or []
        if entry.get("RegionName")
    )


# --------------------------------------------------------------------------- #
# CloudWatch Metric_Client
# --------------------------------------------------------------------------- #


class MetricClient(object):
    """CloudWatch ``get-metric-statistics`` with automatic range chunking."""

    def __init__(self, aws, start, end, warn):
        self.aws = aws
        self.start = start
        self.end = end
        self.warn = warn

    def datapoints(self, region, namespace, metric_name, dimensions, period, statistic="Sum"):
        """Return [(timestamp, value)] for a metric, or ``NO_DATA``.

        ``NO_DATA`` distinguishes "CloudWatch has no datapoints" from a genuine
        measured value of zero.
        """
        dimension_args = []
        for name, value in dimensions:
            dimension_args.append("Name=%s,Value=%s" % (name, value))

        collected = []
        # Keep each call inside the CloudWatch datapoint cap.
        span = timedelta(seconds=period * MAX_DATAPOINTS)
        window_start = self.start
        while window_start < self.end:
            window_end = min(window_start + span, self.end)
            args = [
                "cloudwatch",
                "get-metric-statistics",
                "--namespace",
                namespace,
                "--metric-name",
                metric_name,
                "--start-time",
                iso(window_start),
                "--end-time",
                iso(window_end),
                "--period",
                str(int(period)),
                "--statistics",
                statistic,
            ]
            if dimension_args:
                args += ["--dimensions"] + dimension_args
            payload = self.aws.run(args, region=region)
            for point in (payload or {}).get("Datapoints", []) or []:
                value = point.get(statistic)
                if value is None:
                    continue
                collected.append((parse_ts(point.get("Timestamp")), float(value)))
            window_start = window_end

        if not collected:
            return NO_DATA
        collected.sort(key=lambda item: (item[0] is None, item[0]))
        return collected


def peak(datapoints):
    return max((value for _, value in datapoints), default=0.0)


def total(datapoints):
    return sum(value for _, value in datapoints)


# --------------------------------------------------------------------------- #
# Savings_Calculator / Pricing_Table
# --------------------------------------------------------------------------- #


class PricingTable(object):
    """File-based rate source.

    CSV form (header required)::

        resourceType,attribute,unit,unitPriceUsd
        ebs_storage,gp2,gib-month,0.10
        ebs_storage,gp3,gib-month,0.08
        ebs_iops,io1,unit-month,0.065

    Supported units: ``hour`` (x730), ``month``, ``gib-month`` (x size),
    ``gib-hour`` (x size x730), and ``unit-month`` / ``unit-hour`` as aliases of
    the size-scaled forms for quantities that are not gibibytes.
    """

    def __init__(self, path=None):
        self.path = path
        self.rates = {}
        if path:
            self._load(path)

    def _load(self, path):
        with open(path, "r", encoding="utf-8") as handle:
            head = handle.read(1).strip()
            handle.seek(0)
            if head in ("{", "["):
                payload = json.load(handle)
                for resource_type, entries in (payload or {}).items():
                    for attribute, spec in (entries or {}).items():
                        self.rates[(resource_type, str(attribute))] = (
                            str(spec.get("unit", "month")).lower(),
                            float(spec.get("price", spec.get("unitPriceUsd", 0.0))),
                        )
                return
            for record in csv.DictReader(handle):
                resource_type = (record.get("resourceType") or "").strip()
                if resource_type.startswith("#"):
                    continue
                attribute = (record.get("attribute") or "").strip()
                unit = (record.get("unit") or "month").strip().lower()
                try:
                    price = float(record.get("unitPriceUsd") or 0.0)
                except ValueError:
                    continue
                if resource_type:
                    self.rates[(resource_type, attribute)] = (unit, price)

    @property
    def enabled(self):
        return bool(self.path)

    def monthly(self, resource_type, attribute, quantity=1.0):
        if not self.enabled:
            return None
        entry = self.rates.get((resource_type, str(attribute)))
        if entry is None:
            entry = self.rates.get((resource_type, "default"))
        if entry is None:
            return None
        unit, price = entry
        if unit == "hour":
            return price * HOURS_PER_MONTH
        if unit in ("gib-hour", "unit-hour"):
            return price * float(quantity) * HOURS_PER_MONTH
        if unit in ("gib-month", "unit-month"):
            return price * float(quantity)
        return price


def format_savings(amount):
    if amount is None:
        return NOT_AVAILABLE
    return "$%.2f" % round(float(amount), 2)


def pct(value, decimals=2):
    return ("%%.%df%%%%" % decimals) % float(value)


# --------------------------------------------------------------------------- #
# Detection context and harness
# --------------------------------------------------------------------------- #


class Context(object):
    def __init__(self, args, aws, metrics, pricing, now, warn, account_id):
        self.args = args
        self.aws = aws
        self.metrics = metrics
        self.pricing = pricing
        self.now = now
        self.days = args.days
        self.cutoff = now - timedelta(days=args.days)
        self.warn = warn
        self.account_id = account_id

    def row(self, resource_id, region, description, action, kind=None, savings=None):
        return Row(
            accountId=self.account_id or NOT_AVAILABLE,
            resourceId=resource_id,
            region=region,
            potentialSavings=format_savings(savings),
            description=description,
            action=action,
            link=console_url(kind, region, resource_id) if kind else None,
            savings_amount=savings,
        )


def build_parser(description):
    parser = argparse.ArgumentParser(description=description, add_help=False)
    parser.add_argument("-r", dest="regions")
    parser.add_argument("-d", dest="days", default="30")
    parser.add_argument("-A", dest="account_id")
    parser.add_argument("-U", dest="profile")
    parser.add_argument("-P", dest="pricing_file")
    parser.add_argument("-c", dest="csv_file")
    parser.add_argument("-j", dest="json_output", action="store_true")
    parser.add_argument("-v", dest="verbose", action="store_true")
    return parser


def fail(message, code=EXIT_USAGE):
    sys.stderr.write("%s\n" % message)
    raise SystemExit(code)


def run_detection(name, detect, argv=None, description=None, add_arguments=None):
    """Shared entry point for the AWS ``validate_*.sh`` scripts.

    ``detect(ctx, region)`` returns a list of :class:`Row` for one region.
    """
    argv = list(sys.argv[1:] if argv is None else argv)
    parser = build_parser(description or name)
    if add_arguments is not None:
        add_arguments(parser)
    args, unknown = parser.parse_known_args(argv)
    for token in unknown:
        if token.startswith("-"):
            fail("Unknown option: %s" % token)

    try:
        args.days = int(args.days)
        if args.days <= 0:
            raise ValueError
    except (TypeError, ValueError):
        fail("DAYS (-d) must be a positive integer")

    if shutil.which("aws") is None:
        fail("aws CLI not found on PATH")
    if shutil.which("python3") is None:
        fail("python3 not found on PATH")

    if args.pricing_file and not os.path.isfile(args.pricing_file):
        fail("pricing file not found: %s" % args.pricing_file)

    def warn(message):
        sys.stderr.write("WARN  %s\n" % message)

    aws = Aws(profile=args.profile, verbose=args.verbose)
    account_id = args.account_id or aws.account_id()
    if not account_id:
        fail("no usable AWS credential; run aws configure or set AWS_PROFILE")

    now = datetime.now(timezone.utc)
    metrics = MetricClient(aws, now - timedelta(days=args.days), now, warn)
    pricing = PricingTable(args.pricing_file)
    ctx = Context(args, aws, metrics, pricing, now, warn, account_id)

    sys.stderr.write("=== %s ===\n" % name)

    regions = resolve_regions(aws, args.regions, warn)
    if not regions:
        fail("no regions to evaluate", EXIT_ALL_REGIONS_FAILED)

    sys.stderr.write(
        "Account: %s | Regions: %d | Lookback window: %d days\n"
        % (account_id, len(regions), args.days)
    )

    rows = []
    evaluated = 0
    skipped = 0
    for region in regions:
        sys.stderr.write("--> %s\n" % region)
        try:
            rows.extend(detect(ctx, region) or [])
            evaluated += 1
        except AwsError as exc:
            skipped += 1
            warn("region %s skipped: %s" % (region, exc.summary()))
        except Exception as exc:
            skipped += 1
            warn("region %s skipped: unexpected error: %s" % (region, exc))

    if regions and evaluated == 0:
        emit(rows, args)
        sys.stderr.write("All %d regions failed evaluation.\n" % len(regions))
        return EXIT_ALL_REGIONS_FAILED

    rows.sort(key=lambda row: row.sort_key())
    emit(rows, args)

    savings_total = sum(row.savings_amount or 0.0 for row in rows)
    sys.stderr.write(
        "Regions evaluated: %d | skipped: %d | rows emitted: %d\n"
        % (evaluated, skipped, len(rows))
    )
    sys.stderr.write("Total potential monthly savings: %s\n" % format_savings(savings_total))
    return EXIT_OK


def emit(rows, args):
    if args.json_output:
        sys.stdout.write(json.dumps([row.as_dict() for row in rows], indent=2) + "\n")
    else:
        sys.stdout.write(serialize_rows(rows) + "\n")
    if args.csv_file:
        with open(args.csv_file, "w", newline="", encoding="utf-8") as handle:
            writer = csv.writer(handle)
            writer.writerow(FIELDS)
            for row in rows:
                writer.writerow(row.values())
        sys.stderr.write("CSV written: %s\n" % args.csv_file)

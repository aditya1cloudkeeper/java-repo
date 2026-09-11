"""Shared library for GCP cost-recommendation detection scripts.

Every ``validate_<recommendation>.sh`` script in this directory loads this module
and calls :func:`run_detection` with a project-level detector callback.

Responsibilities
----------------
* CLI parsing shared by all detection scripts (scope, lookback, output options)
* Scope_Resolver      -> expand -p / -f / -o into ACTIVE project IDs
* Metric_Client       -> Cloud Monitoring ``timeSeries.list`` with paging + retry
* Console_URL_Builder -> console.cloud.google.com deep links per resource type
* Savings_Calculator  -> Pricing_Table lookup and monthly projection (730 h)
* Row_Serializer      -> Recommendation_Layout Markdown table
* Row_Parser          -> Recommendation_Layout Markdown table -> rows

Only the Python standard library and the ``gcloud`` executable are used.
Every GCP call is a Read_Only_Operation (list / get / describe / timeSeries.list).
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
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

HOURS_PER_MONTH = 730
MONITORING_ROOT = "https://monitoring.googleapis.com/v3"
NO_DATA = "NO_DATA"
NOT_AVAILABLE = "N/A"

FIELDS = (
    "organizationId",
    "projectId",
    "resourceId",
    "region",
    "potentialSavings",
    "description",
    "action",
)

HEADERS = (
    "Organization ID",
    "Project ID",
    "Resource ID",
    "Region",
    "Potential Savings",
    "Description",
    "Action",
)

ALIGNMENT_ROW = "| " + " | ".join([":----"] * 7) + " |"

# Matches a "|" that is not preceded by a backslash (an unescaped cell divider).
_CELL_SPLIT_RE = re.compile(r"(?<!\\)\|")

EXIT_OK = 0
EXIT_USAGE = 1
EXIT_ALL_PROJECTS_FAILED = 2

# --------------------------------------------------------------------------- #
# Region mapping table (References section of the explainer documents)
# --------------------------------------------------------------------------- #

REGION_FRIENDLY_NAMES = {
    "us-west1": "Oregon, USA",
    "us-west2": "Los Angeles, California, USA",
    "us-west3": "Salt Lake City, Utah, USA",
    "us-west4": "Las Vegas, Nevada, USA",
    "us-central1": "Council Bluffs, Iowa, USA",
    "us-east1": "Moncks Corner, South Carolina, USA",
    "us-east4": "Ashburn, Virginia, USA",
    "us-east5": "Columbus, Ohio, USA",
    "us-south1": "Dallas, Texas, USA",
    "northamerica-northeast1": "Montreal, Canada",
    "northamerica-northeast2": "Toronto, Canada",
    "southamerica-east1": "Sao Paulo, Brazil",
    "southamerica-west1": "Santiago, Chile",
    "europe-west1": "St. Ghislain, Belgium",
    "europe-west2": "London, UK",
    "europe-west3": "Frankfurt, Germany",
    "europe-west4": "Eemshaven, Netherlands",
    "europe-west6": "Zurich, Switzerland",
    "europe-west8": "Milan, Italy",
    "europe-west9": "Paris, France",
    "europe-west10": "Berlin, Germany",
    "europe-west12": "Turin, Italy",
    "europe-central2": "Warsaw, Poland",
    "europe-north1": "Hamina, Finland",
    "europe-southwest1": "Madrid, Spain",
    "me-west1": "Tel Aviv, Israel",
    "me-central1": "Doha, Qatar",
    "me-central2": "Dammam, Saudi Arabia",
    "asia-south1": "Mumbai, India",
    "asia-south2": "Delhi, India",
    "asia-southeast1": "Jurong West, Singapore",
    "asia-southeast2": "Jakarta, Indonesia",
    "asia-east1": "Changhua County, Taiwan",
    "asia-east2": "Hong Kong",
    "asia-northeast1": "Tokyo, Japan",
    "asia-northeast2": "Osaka, Japan",
    "asia-northeast3": "Seoul, South Korea",
    "australia-southeast1": "Sydney, Australia",
    "australia-southeast2": "Melbourne, Australia",
    "africa-south1": "Johannesburg, South Africa",
}

_ZONE_RE = re.compile(r"^(?P<region>[a-z]+-[a-z]+\d+)-(?P<zone>[a-z])$")


def is_zone(location: str) -> bool:
    return bool(_ZONE_RE.match(location or ""))


def region_of(location: str) -> str:
    """Return the region for a zone, or the location itself for a region."""
    match = _ZONE_RE.match(location or "")
    return match.group("region") if match else (location or "")


def friendly_location(location: str) -> str:
    """Render a location using the region mapping table (``-F`` option)."""
    if not location:
        return NOT_AVAILABLE
    if location == "global":
        return "global"
    region = region_of(location)
    friendly = REGION_FRIENDLY_NAMES.get(region)
    if friendly is None:
        return location
    if is_zone(location):
        return "%s (%s)" % (friendly, location)
    return friendly


def last_segment(value: str) -> str:
    """Reduce a fully qualified GCP URL to its final path segment."""
    if not value:
        return ""
    return value.rstrip("/").rsplit("/", 1)[-1]


# --------------------------------------------------------------------------- #
# Recommendation_Row + Row_Serializer + Row_Parser
# --------------------------------------------------------------------------- #


class MalformedRow(Exception):
    """Raised by :func:`parse_table` for a row whose cell count is not seven."""

    code = "MALFORMED_ROW"

    def __init__(self, index: int, cell_count: int):
        super().__init__("MALFORMED_ROW at row %d (%d cells)" % (index, cell_count))
        self.index = index
        self.cell_count = cell_count


class Row(object):
    """One Recommendation_Row."""

    __slots__ = FIELDS + ("_link", "_savings_amount")

    def __init__(
        self,
        organizationId=NOT_AVAILABLE,
        projectId="",
        resourceId="",
        region="",
        potentialSavings=NOT_AVAILABLE,
        description="",
        action="",
        link=None,
        savings_amount=None,
    ):
        self.organizationId = organizationId
        self.projectId = projectId
        self.resourceId = resourceId
        self.region = region
        self.potentialSavings = potentialSavings
        self.description = description
        self.action = action
        self._link = link
        self._savings_amount = savings_amount

    # -- values -----------------------------------------------------------
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
        return (self.projectId, self.region, self.resourceId)

    def __eq__(self, other):
        return isinstance(other, Row) and self.values() == other.values()

    def __repr__(self):
        return "Row(%r)" % (self.values(),)


def _escape_cell(value) -> str:
    text = "" if value is None else str(value)
    text = text.replace("|", r"\|")
    text = re.sub(r"[\r\n]+", " ", text)
    return text.strip()


def _display_cells(row: Row, friendly: bool, org_name: str = None):
    org = row.organizationId
    if org_name and org not in ("", NOT_AVAILABLE):
        org = "%s (%s)" % (org_name, org)

    resource = row.resourceId
    if row.link:
        resource = "[%s](%s)" % (row.resourceId, row.link)

    region = friendly_location(row.region) if friendly else row.region

    return [org, row.projectId, resource, region, row.potentialSavings, row.description, row.action]


def serialize_rows(rows, friendly: bool = False, org_name: str = None) -> str:
    """Row_Serializer: render rows as a Recommendation_Layout Markdown table."""
    lines = ["| " + " | ".join(HEADERS) + " |", ALIGNMENT_ROW]
    for row in rows:
        cells = [_escape_cell(cell) for cell in _display_cells(row, friendly, org_name)]
        lines.append("| " + " | ".join(cells) + " |")
    return "\n".join(lines)


def parse_table(text: str):
    """Row_Parser: read a Recommendation_Layout table and return Row objects.

    Raises :class:`MalformedRow` when a data row does not hold seven cells.
    """
    rows = []
    index = 0
    for raw in text.splitlines():
        line = raw.strip()
        if not line.startswith("|"):
            continue
        index += 1
        # Split on unescaped pipes only, so a "\|" inside a cell stays put.
        body = line[1:-1] if line.endswith("|") and len(line) > 1 else line[1:]
        cells = [cell.strip() for cell in _CELL_SPLIT_RE.split(body)]
        if index == 1 and [c.lower() for c in cells] == [h.lower() for h in HEADERS]:
            continue
        if set("".join(cells)) <= set(":- "):
            continue
        if len(cells) != 7:
            raise MalformedRow(index, len(cells))
        cells = [cell.replace(r"\|", "|") for cell in cells]
        rows.append(Row(*cells))
    return rows


# --------------------------------------------------------------------------- #
# Console_URL_Builder
# --------------------------------------------------------------------------- #

_SAFE = "-_.~"


def _quote(segment: str) -> str:
    return urllib.parse.quote(str(segment), safe=_SAFE)


def console_url(kind: str, project: str, name: str, location: str = None):
    """Return a console deep link, or ``None`` when the type has no mapping."""
    if kind == "disk":
        path = "/compute/disksDetail/zones/%s/disks/%s" % (_quote(location), _quote(name))
    elif kind == "regional-disk":
        path = "/compute/disksDetail/regions/%s/disks/%s" % (_quote(location), _quote(name))
    elif kind == "instance":
        path = "/compute/instancesDetail/zones/%s/instances/%s" % (_quote(location), _quote(name))
    elif kind == "snapshot":
        path = "/compute/snapshotsDetail/projects/%s/global/snapshots/%s" % (
            _quote(project),
            _quote(name),
        )
    elif kind == "sql":
        path = "/sql/instances/%s/overview" % _quote(name)
    elif kind == "filestore":
        path = "/filestore/locations/%s/instances/%s" % (_quote(location), _quote(name))
    elif kind == "run":
        path = "/run/detail/%s/%s/metrics" % (_quote(location), _quote(name))
    elif kind == "redis":
        path = "/memorystore/redis/locations/%s/instances/%s/details" % (
            _quote(location),
            _quote(name),
        )
    elif kind == "dns-zone":
        path = "/net-services/dns/zones/%s" % _quote(name)
    elif kind == "router":
        path = "/hybrid/routers/details/%s/%s" % (_quote(location), _quote(name))
    elif kind == "bucket":
        path = "/storage/browser/%s" % _quote(name)
    elif kind == "vertex-endpoint":
        path = "/vertex-ai/online-prediction/locations/%s/endpoints/%s" % (
            _quote(location),
            _quote(name),
        )
    elif kind == "appengine-service":
        path = "/appengine/services"
    elif kind == "appengine-version":
        path = "/appengine/versions"
    else:
        # No path mapping: the Row_Serializer renders the plain resource name.
        return None
    query = urllib.parse.urlencode({"project": project}, quote_via=urllib.parse.quote, safe=_SAFE)
    return "https://console.cloud.google.com%s?%s" % (path, query)


# --------------------------------------------------------------------------- #
# Time helpers
# --------------------------------------------------------------------------- #


def parse_ts(value):
    """Parse an RFC 3339 timestamp into an aware UTC datetime, or None."""
    if not value:
        return None
    text = str(value).strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    # Trim fractional seconds to microsecond precision.
    text = re.sub(r"\.(\d{6})\d+", r".\1", text)
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def rfc3339(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def ymd_breakdown(start: datetime, end: datetime):
    """Split an elapsed interval into whole years, months, and days."""
    if start is None or end is None or end < start:
        return (0, 0, 0)
    years = end.year - start.year
    months = end.month - start.month
    days = end.day - start.day
    if days < 0:
        months -= 1
        previous_month_end = end.replace(day=1) - timedelta(days=1)
        days += previous_month_end.day
    if months < 0:
        years -= 1
        months += 12
    return (years, months, days)


def ymd_phrase(start: datetime, end: datetime) -> str:
    years, months, days = ymd_breakdown(start, end)
    return "%d Years %d Months and %d Days" % (years, months, days)


def elapsed_days(start: datetime, end: datetime) -> float:
    if start is None or end is None:
        return 0.0
    return (end - start).total_seconds() / 86400.0


# --------------------------------------------------------------------------- #
# gcloud wrapper
# --------------------------------------------------------------------------- #


class GcpError(Exception):
    """A classified failure from a gcloud invocation."""

    def __init__(self, kind: str, detail: str, service: str = None):
        super().__init__(detail)
        self.kind = kind  # permission_denied | api_disabled | not_found | other
        self.detail = detail
        self.service = service

    def summary(self) -> str:
        if self.kind == "api_disabled":
            return "service API not enabled (%s)" % (self.service or "unknown service")
        if self.kind == "permission_denied":
            return "permission denied (HTTP 403)"
        if self.kind == "not_found":
            return "not found (HTTP 404)"
        return self.detail


_SERVICE_RE = re.compile(r"([a-z0-9.-]+\.googleapis\.com)")


def _classify(stderr: str) -> GcpError:
    text = (stderr or "").strip()
    lowered = text.lower()
    one_line = " ".join(text.split())[:400]
    if "has not been used in project" in lowered or "is disabled" in lowered or "accessnotconfigured" in lowered:
        match = _SERVICE_RE.search(text)
        return GcpError("api_disabled", one_line, match.group(1) if match else None)
    if "403" in lowered or "permission denied" in lowered or "does not have permission" in lowered:
        return GcpError("permission_denied", one_line)
    if "404" in lowered or "was not found" in lowered or "not found" in lowered:
        return GcpError("not_found", one_line)
    return GcpError("other", one_line or "gcloud invocation failed")


class ReadOnlyViolation(Exception):
    """Raised when a caller tries to run a gcloud verb that could mutate state."""


class Gcloud(object):
    """Read-only gcloud runner.

    Only the verbs in :attr:`READ_ONLY_VERBS` may be executed. Anything else
    raises :class:`ReadOnlyViolation` before a subprocess is spawned, so a
    Detection_Script cannot create, update, or delete a GCP resource even if a
    future edit tries to.
    """

    READ_ONLY_VERBS = frozenset(
        (
            "list",
            "list-instances",
            "describe",
            "get",
            "get-ancestors",
            "get-iam-policy",
            "print-access-token",
        )
    )

    def __init__(self, impersonate=None, verbose=False):
        self.impersonate = impersonate
        self.verbose = verbose

    @classmethod
    def assert_read_only(cls, args):
        """Verify that the last positional token is a read-only verb."""
        # Only the tokens before the first flag can hold the verb; the command
        # shape is "<group>... <verb> [args]", so the first allowlisted token is
        # the verb and everything after it is an argument.
        leading = []
        for token in args:
            if str(token).startswith("-"):
                break
            leading.append(str(token))
        if not any(token in cls.READ_ONLY_VERBS for token in leading):
            raise ReadOnlyViolation(
                "refusing to run non read-only gcloud command: %s" % " ".join(leading)
            )

    def run(self, args, project=None, json_output=True, allow_failure=False):
        self.assert_read_only(args)
        cmd = ["gcloud"] + list(args)
        if project:
            cmd += ["--project", project]
        if json_output:
            cmd += ["--format", "json"]
        if self.impersonate:
            cmd += ["--impersonate-service-account=%s" % self.impersonate]
        cmd += ["--quiet"]
        if self.verbose:
            sys.stderr.write("  + %s\n" % " ".join(cmd))
        completed = subprocess.run(cmd, capture_output=True, text=True)
        if completed.returncode != 0:
            if allow_failure:
                return None
            raise _classify(completed.stderr)
        if not json_output:
            return completed.stdout
        payload = completed.stdout.strip()
        if not payload:
            return []
        try:
            return json.loads(payload)
        except ValueError as exc:
            raise GcpError("other", "unparseable gcloud JSON output: %s" % exc)

    def access_token(self):
        self.assert_read_only(["auth", "print-access-token"])
        cmd = ["gcloud", "auth", "print-access-token"]
        if self.impersonate:
            cmd += ["--impersonate-service-account=%s" % self.impersonate]
        completed = subprocess.run(cmd, capture_output=True, text=True)
        if completed.returncode != 0 or not completed.stdout.strip():
            return None
        return completed.stdout.strip()


# --------------------------------------------------------------------------- #
# Scope_Resolver
# --------------------------------------------------------------------------- #


class ScopeResolver(object):
    def __init__(self, gcloud: Gcloud, warn):
        self.gcloud = gcloud
        self.warn = warn

    def projects(self, args):
        if args.project:
            # -p takes one project ID or a comma-separated list of them.
            ordered = []
            for item in args.project.split(","):
                project_id = item.strip()
                if project_id and project_id not in ordered:
                    ordered.append(project_id)
            return ordered
        parent = (
            "organizations/%s" % args.organization
            if args.organization
            else "folders/%s" % args.folder
        )
        seen = []
        seen_set = set()
        self._walk(parent, seen, seen_set)
        return seen

    def _walk(self, parent, ordered, seen):
        for project in self.gcloud.run(
            ["projects", "list", "--filter", "parent.id=%s" % parent.split("/")[-1]]
        ) or []:
            if project.get("lifecycleState") != "ACTIVE":
                continue
            project_id = project.get("projectId")
            if project_id and project_id not in seen:
                seen.add(project_id)
                ordered.append(project_id)
        for folder in self.gcloud.run(
            ["resource-manager", "folders", "list", "--folder" if parent.startswith("folders/") else "--organization", parent.split("/")[-1]]
        ) or []:
            if folder.get("lifecycleState") not in (None, "ACTIVE"):
                continue
            name = folder.get("name")
            if name:
                self._walk(name if name.startswith("folders/") else "folders/%s" % name, ordered, seen)

    def organization_id(self, project_id):
        """Return the numeric organization ancestor of a project, or ``N/A``."""
        try:
            ancestors = self.gcloud.run(["projects", "get-ancestors", project_id], json_output=True)
        except GcpError as exc:
            self.warn("project %s: cannot resolve organization ancestry: %s" % (project_id, exc.summary()))
            return NOT_AVAILABLE
        for entry in ancestors or []:
            node = entry.get("id") if isinstance(entry, dict) else None
            node_type = entry.get("type") if isinstance(entry, dict) else None
            if node_type == "organization" and node:
                return str(node)
        self.warn("project %s: no organization ancestor found" % project_id)
        return NOT_AVAILABLE


# --------------------------------------------------------------------------- #
# Metric_Client
# --------------------------------------------------------------------------- #


class MetricClient(object):
    """Cloud Monitoring ``timeSeries.list`` client with paging and retries."""

    MAX_RETRIES = 3

    def __init__(self, token, start, end, warn):
        self.token = token
        self.start = start
        self.end = end
        self.warn = warn

    def points(
        self,
        project,
        metric_type,
        resource_filter,
        aligner,
        alignment_period,
        cross_series_reducer=None,
    ):
        """Return a list of numeric point values, or ``NO_DATA``.

        ``NO_DATA`` distinguishes "Monitoring returned no time series" from a
        genuine measured value of zero.
        """
        params = [
            ("filter", 'metric.type="%s"%s' % (metric_type, resource_filter)),
            ("interval.startTime", rfc3339(self.start)),
            ("interval.endTime", rfc3339(self.end)),
            ("aggregation.alignmentPeriod", "%ds" % int(alignment_period)),
            ("aggregation.perSeriesAligner", aligner),
            ("view", "FULL"),
        ]
        if cross_series_reducer:
            params.append(("aggregation.crossSeriesReducer", cross_series_reducer))

        collected = []
        series_seen = False
        page_token = None
        while True:
            query = list(params)
            if page_token:
                query.append(("pageToken", page_token))
            url = "%s/projects/%s/timeSeries?%s" % (
                MONITORING_ROOT,
                urllib.parse.quote(project, safe=_SAFE),
                urllib.parse.urlencode(query),
            )
            payload = self._get(url)
            if payload is None:
                raise MetricUnavailable(metric_type)
            for series in payload.get("timeSeries", []) or []:
                series_seen = True
                for point in series.get("points", []) or []:
                    value = _point_value(point)
                    if value is not None:
                        collected.append(value)
            page_token = payload.get("nextPageToken")
            if not page_token:
                break
        if not series_seen:
            return NO_DATA
        return collected

    def _get(self, url):
        delay = 1.0
        for attempt in range(1, self.MAX_RETRIES + 2):
            # Method is pinned to GET: timeSeries.list is the only API touched.
            request = urllib.request.Request(
                url, headers={"Authorization": "Bearer %s" % self.token}, method="GET"
            )
            try:
                with urllib.request.urlopen(request, timeout=120) as response:
                    return json.loads(response.read().decode("utf-8"))
            except urllib.error.HTTPError as exc:
                retryable = exc.code == 429 or 500 <= exc.code <= 599
                if not retryable or attempt > self.MAX_RETRIES:
                    raise MetricHttpError(exc.code)
            except (urllib.error.URLError, TimeoutError):
                if attempt > self.MAX_RETRIES:
                    raise MetricHttpError(0)
            time.sleep(delay)
            delay *= 2
        return None


def read_only_get(url, token, accept="application/json", retries=3, timeout=120):
    """Issue a single read-only HTTP GET and return the raw response body.

    The method is pinned to GET, so this helper cannot mutate remote state.
    Retries 429 and 5xx with exponential backoff starting at 1 second.
    """
    delay = 1.0
    for attempt in range(1, retries + 2):
        request = urllib.request.Request(
            url,
            headers={"Authorization": "Bearer %s" % token, "Accept": accept},
            method="GET",
        )
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return response.read()
        except urllib.error.HTTPError as exc:
            retryable = exc.code == 429 or 500 <= exc.code <= 599
            if not retryable or attempt > retries:
                raise MetricHttpError(exc.code)
        except (urllib.error.URLError, TimeoutError):
            if attempt > retries:
                raise MetricHttpError(0)
        time.sleep(delay)
        delay *= 2
    raise MetricHttpError(0)


def get_json(url, token):
    return json.loads(read_only_get(url, token).decode("utf-8"))


def get_text(url, token, accept="application/xml"):
    return read_only_get(url, token, accept=accept).decode("utf-8")


class MetricUnavailable(Exception):
    def __init__(self, metric_type):
        super().__init__("no response for %s" % metric_type)
        self.metric_type = metric_type


class MetricHttpError(Exception):
    def __init__(self, status):
        super().__init__("Cloud Monitoring returned HTTP %s" % status)
        self.status = status


def _point_value(point):
    value = point.get("value") or {}
    for key in ("doubleValue", "int64Value", "distributionValue"):
        if key not in value:
            continue
        raw = value[key]
        if key == "distributionValue":
            raw = (raw or {}).get("mean")
        if raw is None:
            return None
        try:
            return float(raw)
        except (TypeError, ValueError):
            return None
    return None


def total(values):
    return sum(values) if values else 0.0


def peak(values):
    return max(values) if values else 0.0


# --------------------------------------------------------------------------- #
# Savings_Calculator / Pricing_Table
# --------------------------------------------------------------------------- #


class PricingTable(object):
    """File-based rate source.

    CSV form (header required)::

        resourceType,attribute,unit,unitPriceUsd
        machine_type,e2-medium,hour,0.033503
        disk,pd-balanced,gib-month,0.10
        snapshot,default,gib-month,0.026
        filestore,BASIC_HDD,gib-month,0.20
        redis,BASIC,gib-hour,0.049
        cloudsql,db-n1-standard-1,hour,0.0965

    JSON form: ``{"machine_type": {"e2-medium": {"unit": "hour", "price": 0.03}}}``

    Supported units: ``hour`` (multiplied by 730), ``month``, ``gib-month``
    (multiplied by size), ``gib-hour`` (multiplied by size and 730).
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
                    continue  # comment line
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

    def monthly(self, resource_type, attribute, size_gib=1.0):
        """Projected monthly USD cost, or ``None`` when no rate matches."""
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
        # "unit-*" are aliases of "gib-*" for quantities that are not gibibytes
        # (vCPU counts, provisioned IOPS, nodes).
        if unit in ("gib-hour", "unit-hour"):
            return price * float(size_gib) * HOURS_PER_MONTH
        if unit in ("gib-month", "unit-month"):
            return price * float(size_gib)
        return price

    def delta(self, resource_type, current, recommended, current_size=1.0, new_size=None):
        """Monthly saving from moving ``current`` -> ``recommended``.

        Returns ``None`` when either side has no matching rate, so an
        over-provisioned finding never reports a half-computed number.
        """
        if not self.enabled:
            return None
        if new_size is None:
            new_size = current_size
        now_cost = self.monthly(resource_type, current, current_size)
        new_cost = self.monthly(resource_type, recommended, new_size)
        if now_cost is None or new_cost is None:
            return None
        return max(0.0, now_cost - new_cost)


def format_savings(amount):
    if amount is None:
        return NOT_AVAILABLE
    return "$%.2f" % round(float(amount), 2)


def pct(value, decimals=2):
    """Render a percentage value already expressed in percent units."""
    return ("%%.%df%%%%" % decimals) % float(value)


def gib(num_bytes):
    return float(num_bytes) / float(1024 ** 3)


# --------------------------------------------------------------------------- #
# Detection context and harness
# --------------------------------------------------------------------------- #


class Context(object):
    """Everything a detector callback needs."""

    def __init__(self, args, gcloud, resolver, metrics, pricing, now, warn, token=None):
        self.args = args
        self.gcloud = gcloud
        self.resolver = resolver
        self.metrics = metrics
        self.pricing = pricing
        self.now = now
        self.days = args.days
        self.cutoff = now - timedelta(days=args.days)
        self.warn = warn
        self.token = token

    def get_json(self, url):
        """Read-only JSON GET against a Google API."""
        return get_json(url, self.token)

    def get_text(self, url, accept="application/xml"):
        """Read-only GET returning raw text (used for the GCS XML API)."""
        return get_text(url, self.token, accept=accept)

    def older_than_threshold(self, timestamp):
        moment = parse_ts(timestamp) if not isinstance(timestamp, datetime) else timestamp
        return moment is not None and moment <= self.cutoff

    def row(self, project, name, region, description, action, kind=None, link_name=None,
            savings=None, location=None):
        url = console_url(kind, project, name, location or region) if kind else None
        return Row(
            organizationId=self.org_id(project),
            projectId=project,
            resourceId=link_name or name,
            region=region,
            potentialSavings=format_savings(savings),
            description=description,
            action=action,
            link=url,
            savings_amount=savings,
        )

    # Organization IDs are resolved once per project.
    _org_cache = None

    def org_id(self, project):
        if self.args.organization:
            return str(self.args.organization)
        if self._org_cache is None:
            self._org_cache = {}
        if project not in self._org_cache:
            self._org_cache[project] = self.resolver.organization_id(project)
        return self._org_cache[project]


def build_parser(description):
    parser = argparse.ArgumentParser(description=description, add_help=False)
    parser.add_argument("-p", dest="project")
    parser.add_argument("-o", dest="organization")
    parser.add_argument("-f", dest="folder")
    parser.add_argument("-d", dest="days", default="30")
    parser.add_argument("-n", dest="organization_name")
    parser.add_argument("-P", dest="pricing_file")
    parser.add_argument("-i", dest="impersonate")
    parser.add_argument("-c", dest="csv_file")
    parser.add_argument("-j", dest="json_output", action="store_true")
    parser.add_argument("-F", dest="friendly", action="store_true")
    parser.add_argument("-v", dest="verbose", action="store_true")
    return parser


def fail(message, code=EXIT_USAGE):
    sys.stderr.write("%s\n" % message)
    raise SystemExit(code)


def run_detection(name, detect, argv=None, description=None, add_arguments=None):
    """Shared entry point used by every ``validate_<recommendation>.sh`` script.

    ``detect(ctx, project)`` returns a list of :class:`Row` for one project.
    ``add_arguments(parser)`` may register recommendation-specific options.
    """
    argv = list(sys.argv[1:] if argv is None else argv)
    parser = build_parser(description or name)
    if add_arguments is not None:
        add_arguments(parser)
    args, unknown = parser.parse_known_args(argv)
    for token in unknown:
        if token.startswith("-"):
            fail("Unknown option: %s" % token)

    scopes = [bool(args.project), bool(args.organization), bool(args.folder)]
    if not any(scopes):
        fail("one of -p, -o, or -f is required")
    if sum(1 for flag in scopes if flag) > 1:
        fail("-p, -o, and -f are mutually exclusive")

    try:
        args.days = int(args.days)
        if args.days <= 0:
            raise ValueError
    except (TypeError, ValueError):
        fail("DAYS (-d) must be a positive integer")

    if shutil.which("gcloud") is None:
        fail("gcloud CLI not found on PATH")
    if shutil.which("python3") is None:
        fail("python3 not found on PATH")

    if args.pricing_file and not os.path.isfile(args.pricing_file):
        fail("pricing file not found: %s" % args.pricing_file)

    warnings = []

    def warn(message):
        warnings.append(message)
        sys.stderr.write("WARN  %s\n" % message)

    gcloud = Gcloud(impersonate=args.impersonate, verbose=args.verbose)
    token = gcloud.access_token()
    if not token:
        fail("no active gcloud credential; run gcloud auth login")

    now = datetime.now(timezone.utc)
    metrics = MetricClient(token, now - timedelta(days=args.days), now, warn)
    pricing = PricingTable(args.pricing_file)
    resolver = ScopeResolver(gcloud, warn)

    sys.stderr.write("=== %s ===\n" % name)

    try:
        projects = resolver.projects(args)
    except GcpError as exc:
        fail("scope resolution failed: %s" % exc.summary(), EXIT_ALL_PROJECTS_FAILED)

    sys.stderr.write(
        "Target projects: %d | Lookback window: %d days | Age threshold: %d days\n"
        % (len(projects), args.days, args.days)
    )

    ctx = Context(args, gcloud, resolver, metrics, pricing, now, warn, token=token)

    rows = []
    evaluated = 0
    skipped = 0
    for project in projects:
        sys.stderr.write("--> %s\n" % project)
        try:
            rows.extend(detect(ctx, project) or [])
            evaluated += 1
        except GcpError as exc:
            skipped += 1
            warn("project %s skipped: %s" % (project, exc.summary()))
        except MetricHttpError as exc:
            skipped += 1
            warn("project %s skipped: %s" % (project, exc))
        except Exception as exc:  # keep the scan alive across hundreds of projects
            skipped += 1
            warn("project %s skipped: unexpected error: %s" % (project, exc))

    if projects and evaluated == 0:
        emit(rows, args, ctx)
        sys.stderr.write("All %d target projects failed evaluation.\n" % len(projects))
        return EXIT_ALL_PROJECTS_FAILED

    rows.sort(key=lambda row: row.sort_key())
    emit(rows, args, ctx)

    savings_total = sum(row.savings_amount or 0.0 for row in rows)
    sys.stderr.write(
        "Projects evaluated: %d | skipped: %d | rows emitted: %d\n"
        % (evaluated, skipped, len(rows))
    )
    sys.stderr.write("Total potential monthly savings: %s\n" % format_savings(savings_total))
    return EXIT_OK


def emit(rows, args, ctx):
    if args.json_output:
        sys.stdout.write(json.dumps([row.as_dict() for row in rows], indent=2) + "\n")
    else:
        sys.stdout.write(
            serialize_rows(rows, friendly=args.friendly, org_name=args.organization_name) + "\n"
        )
    if args.csv_file:
        with open(args.csv_file, "w", newline="", encoding="utf-8") as handle:
            writer = csv.writer(handle)
            writer.writerow(FIELDS)
            for row in rows:
                writer.writerow(row.values())
        sys.stderr.write("CSV written: %s\n" % args.csv_file)

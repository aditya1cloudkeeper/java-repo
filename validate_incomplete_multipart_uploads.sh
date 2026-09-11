#!/usr/bin/env bash
# Recommendation : Incomplete Multipart Uploads (Cleaner)
# Source doc     : GCP Cleaner __ Multipart uploads.md
#
# Detection logic:
#   1. List every Cloud Storage bucket in each target project (JSON API).
#   2. Skip buckets whose lifecycle already aborts incomplete multipart uploads.
#   3. List in-progress multipart uploads per bucket via the XML API "?uploads",
#      following NextKeyMarker / NextUploadIdMarker pagination.
#   4. Keep uploads initiated at least DAYS ago, then list their parts
#      ("?uploadId=") and sum the part sizes. The uploads listing does not carry
#      sizes, so the parts listing is where the byte count comes from.
#   5. Total abandoned bytes > MIN_GIB (default 1 GiB) -> report the bucket.
#   6. Pricing uses the upload's own storage class when present, otherwise the
#      bucket default, since parts inherit the bucket's storage class behaviour.
#
#   Every call here is a GET; nothing is aborted or deleted.
#
# Usage: validate_incomplete_multipart_uploads.sh (-p PROJECTS | -o ORG_ID | -f FOLDER_ID) [options]
#
# Options:
#   -p PROJECTS     evaluate one project, or several as a comma-separated list
#   -o ORG_ID       evaluate every ACTIVE project under an organization
#   -f FOLDER_ID    evaluate every ACTIVE project under a folder
#   -d DAYS         minimum upload age in days (default 30)
#   -g MIN_GIB      minimum abandoned size in GiB to report (default 1)
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
import xml.etree.ElementTree as ElementTree

sys.path.insert(0, os.environ["GCP_RECO_LIB_DIR"])

from gcp_reco_lib import (
    MetricHttpError,
    gib,
    parse_ts,
    run_detection,
)

STORAGE_JSON = "https://storage.googleapis.com/storage/v1"
STORAGE_XML = "https://storage.googleapis.com"

ACTION = (
    "Review and delete incomplete multipart uploads to reduce unnecessary storage costs"
)


def add_arguments(parser):
    parser.add_argument("-g", dest="min_gib", default="1")


def strip_ns(tag):
    return tag.rsplit("}", 1)[-1]


def findall(element, name):
    return [child for child in element if strip_ns(child.tag) == name]


def text_of(element, name, default=""):
    for child in element:
        if strip_ns(child.tag) == name:
            return (child.text or "").strip()
    return default


def buckets(ctx, project):
    found = []
    page_token = None
    while True:
        params = {"project": project, "projection": "full"}
        if page_token:
            params["pageToken"] = page_token
        payload = ctx.get_json("%s/b?%s" % (STORAGE_JSON, urllib.parse.urlencode(params)))
        found.extend((payload or {}).get("items", []) or [])
        page_token = (payload or {}).get("nextPageToken")
        if not page_token:
            break
    return found


def aborts_multipart(bucket):
    """True when a lifecycle rule already cleans up incomplete uploads."""
    rules = ((bucket.get("lifecycle") or {}).get("rule")) or []
    for rule in rules:
        action = (rule.get("action") or {}).get("type", "")
        if action == "AbortIncompleteMultipartUpload":
            return True
    return False


def list_uploads(ctx, bucket_name):
    """Every in-progress multipart upload in the bucket."""
    uploads = []
    key_marker = None
    upload_id_marker = None
    while True:
        params = [("uploads", "")]
        if key_marker:
            params.append(("key-marker", key_marker))
        if upload_id_marker:
            params.append(("upload-id-marker", upload_id_marker))
        url = "%s/%s?%s" % (
            STORAGE_XML,
            urllib.parse.quote(bucket_name),
            urllib.parse.urlencode(params),
        )
        body = ctx.get_text(url)
        root = ElementTree.fromstring(body)
        for entry in findall(root, "Upload"):
            uploads.append(
                {
                    "key": text_of(entry, "Key"),
                    "upload_id": text_of(entry, "UploadId"),
                    "initiated": text_of(entry, "Initiated"),
                    "storage_class": text_of(entry, "StorageClass"),
                }
            )
        if text_of(root, "IsTruncated").lower() != "true":
            break
        key_marker = text_of(root, "NextKeyMarker")
        upload_id_marker = text_of(root, "NextUploadIdMarker")
        if not key_marker and not upload_id_marker:
            break
    return uploads


def upload_bytes(ctx, bucket_name, key, upload_id):
    """Sum the sizes of the parts already stored for one upload."""
    size = 0
    part_marker = None
    while True:
        params = [("uploadId", upload_id)]
        if part_marker:
            params.append(("part-number-marker", part_marker))
        url = "%s/%s/%s?%s" % (
            STORAGE_XML,
            urllib.parse.quote(bucket_name),
            urllib.parse.quote(key),
            urllib.parse.urlencode(params),
        )
        body = ctx.get_text(url)
        root = ElementTree.fromstring(body)
        for part in findall(root, "Part"):
            try:
                size += int(text_of(part, "Size") or 0)
            except ValueError:
                continue
        if text_of(root, "IsTruncated").lower() != "true":
            break
        part_marker = text_of(root, "NextPartNumberMarker")
        if not part_marker:
            break
    return size


def detect(ctx, project):
    try:
        min_gib = float(ctx.args.min_gib)
    except (TypeError, ValueError):
        ctx.warn("MIN_GIB (-g) is not numeric; falling back to 1")
        min_gib = 1.0

    rows = []
    for bucket in buckets(ctx, project):
        name = bucket.get("name", "")
        if not name:
            continue
        if aborts_multipart(bucket):
            continue

        location = (bucket.get("location") or "").lower()
        default_class = bucket.get("storageClass", "")

        try:
            uploads = list_uploads(ctx, name)
        except (MetricHttpError, ElementTree.ParseError) as exc:
            ctx.warn("project %s: bucket %s: multipart listing failed: %s" % (project, name, exc))
            continue

        abandoned = 0
        classes = {}
        for upload in uploads:
            initiated = parse_ts(upload["initiated"])
            if initiated is None or initiated > ctx.cutoff:
                continue
            try:
                size = upload_bytes(ctx, name, upload["key"], upload["upload_id"])
            except (MetricHttpError, ElementTree.ParseError) as exc:
                ctx.warn(
                    "project %s: bucket %s: part listing failed for %s: %s"
                    % (project, name, upload["key"], exc)
                )
                continue
            abandoned += size
            storage_class = upload["storage_class"] or default_class
            classes[storage_class] = classes.get(storage_class, 0) + size

        size_gib = gib(abandoned)
        if size_gib <= min_gib:
            continue

        savings = None
        if ctx.pricing.enabled:
            savings = 0.0
            for storage_class, class_bytes in classes.items():
                rate = ctx.pricing.monthly("gcs_storage", storage_class, gib(class_bytes))
                if rate is None:
                    ctx.warn(
                        "project %s: bucket %s: no pricing rate for storage class %s"
                        % (project, name, storage_class or "unset")
                    )
                    savings = None
                    break
                savings += rate

        rows.append(
            ctx.row(
                project=project,
                name=name,
                region=location,
                description=(
                    "The size of incomplete multipart uploads in your storage bucket is %.2f "
                    "GiB. This costs you additional storage charges." % size_gib
                ),
                action=ACTION,
                kind="bucket",
                savings=savings,
            )
        )
    return rows


raise SystemExit(
    run_detection(
        "Incomplete Multipart Uploads", detect, add_arguments=add_arguments
    )
)
PYTHON

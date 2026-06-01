#!/usr/bin/env python3

import argparse
import os
import re
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import List, Optional, Tuple

try:
    import boto3
    from botocore.exceptions import BotoCoreError, ClientError
except ImportError:  # pragma: no cover
    boto3 = None  # type: ignore[assignment]
    BotoCoreError = Exception  # type: ignore[assignment]
    ClientError = Exception  # type: ignore[assignment]

BUNDLE_SUFFIX = ".tar.gz"
TIMESTAMP_RE = re.compile(r"(\d{4}-\d{2}-\d{2}_\d{2}-\d{2})\.tar\.gz$")


def _require_boto3() -> None:
    if boto3 is None:
        print("boto3 is not installed in this container. S3 operations are disabled.", file=sys.stderr)
        sys.exit(1)


def build_s3_client():
    _require_boto3()

    session_kwargs = {}
    access_key = os.environ.get("S3_ACCESS_KEY_ID")
    secret_key = os.environ.get("S3_SECRET_ACCESS_KEY")
    region = os.environ.get("S3_REGION")
    endpoint_url = os.environ.get("S3_ENDPOINT_URL")

    if access_key and secret_key:
        session_kwargs["aws_access_key_id"] = access_key
        session_kwargs["aws_secret_access_key"] = secret_key
    if region:
        session_kwargs["region_name"] = region

    session = boto3.session.Session(**session_kwargs)  # type: ignore[arg-type]
    return session.client("s3", endpoint_url=endpoint_url)


def get_bucket_name() -> str:
    bucket = os.environ.get("S3_BUCKET_NAME")
    if not bucket:
        print("S3_BUCKET_NAME is not set.", file=sys.stderr)
        sys.exit(1)
    return bucket


def default_s3_prefix() -> str:
    return os.environ.get("S3_PREFIX", "xwiki/backups")


def iter_bundle_files(directory: Path, name_prefix: str) -> List[Path]:
    if not directory.exists():
        return []
    pattern = f"{name_prefix}-*{BUNDLE_SUFFIX}"
    return sorted(directory.glob(pattern))


def should_upload_file(path: Path, max_age_hours: Optional[int]) -> bool:
    if max_age_hours is None:
        return True
    mtime = datetime.fromtimestamp(path.stat().st_mtime, tz=timezone.utc)
    cutoff = datetime.now(tz=timezone.utc) - timedelta(hours=max_age_hours)
    return mtime >= cutoff


def parse_timestamp_from_bundle(path: Path) -> datetime:
    match = TIMESTAMP_RE.search(path.name)
    if match:
        try:
            return datetime.strptime(match.group(1), "%Y-%m-%d_%H-%M").replace(tzinfo=timezone.utc)
        except ValueError:
            pass
    return datetime.fromtimestamp(path.stat().st_mtime, tz=timezone.utc)


def build_s3_key(prefix: str, path: Path) -> str:
    dt = parse_timestamp_from_bundle(path)
    date_prefix = f"{dt.year:04d}/{dt.month:02d}/{dt.day:02d}"
    prefix = prefix.strip("/")
    if prefix:
        return f"{prefix}/{date_prefix}/{path.name}"
    return f"{date_prefix}/{path.name}"


def upload_backups(
    directory: Path,
    prefix: Optional[str],
    name_prefix: str,
    max_age_hours: Optional[int],
) -> int:
    files = iter_bundle_files(directory, name_prefix)
    if not files:
        print(f"No bundle archives found in {directory}", file=sys.stderr)
        return 0

    bucket = get_bucket_name()
    client = build_s3_client()
    effective_prefix = prefix or default_s3_prefix()

    uploaded = 0
    failed = 0
    for path in files:
        if not should_upload_file(path, max_age_hours):
            continue
        key = build_s3_key(effective_prefix, path)
        print(f"Uploading {path} to s3://{bucket}/{key}")
        try:
            client.upload_file(str(path), bucket, key)
            uploaded += 1
        except (BotoCoreError, ClientError) as exc:  # type: ignore[misc]
            print(f"Failed to upload {path}: {exc}", file=sys.stderr)
            failed += 1
    return 1 if failed else 0


def list_backup_items(prefix: Optional[str], limit: Optional[int]) -> List[Tuple[str, datetime, str]]:
    """Return (s3_key, last_modified, bundle_filename) newest first."""
    bucket = get_bucket_name()
    client = build_s3_client()
    effective_prefix = (prefix or default_s3_prefix()).rstrip("/") + "/"

    paginator = client.get_paginator("list_objects_v2")
    items: List[Tuple[str, datetime, str]] = []

    for page in paginator.paginate(Bucket=bucket, Prefix=effective_prefix):
        contents = page.get("Contents") or []
        for obj in contents:
            key = obj.get("Key")
            last_modified = obj.get("LastModified")
            if not key or not isinstance(last_modified, datetime):
                continue
            if not key.endswith(BUNDLE_SUFFIX):
                continue
            items.append((key, last_modified, Path(key).name))

    items.sort(key=lambda x: x[1], reverse=True)
    if limit is not None:
        items = items[:limit]
    return items


def download_backup(key: str, output: Path) -> None:
    bucket = get_bucket_name()
    client = build_s3_client()

    output.parent.mkdir(parents=True, exist_ok=True)
    print(f"Downloading s3://{bucket}/{key} to {output}")
    try:
        client.download_file(bucket, key, str(output))
    except (BotoCoreError, ClientError) as exc:  # type: ignore[misc]
        print(f"Failed to download {key}: {exc}", file=sys.stderr)
        sys.exit(1)


def backup_name_prefix() -> str:
    return os.environ.get("XWIKI_BACKUP_NAME", "xwiki-backup")


def parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="XWiki unified backup bundles: upload, list, download to/from S3.",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    upload = subparsers.add_parser("upload", help="Upload local bundle archives to S3")
    upload.add_argument(
        "--backups-dir",
        type=Path,
        default=os.environ.get("XWIKI_BACKUPS_PATH", "/srv/xwiki/backups"),
    )
    upload.add_argument("--prefix", type=str, default=None)
    upload.add_argument("--name-prefix", type=str, default=None)
    upload.add_argument(
        "--max-age-hours",
        type=int,
        default=26,
        help="Only upload bundles newer than this many hours (default: 26)",
    )

    list_cmd = subparsers.add_parser("list", help="List bundle archives in S3")
    list_cmd.add_argument("--prefix", type=str, default=None)
    list_cmd.add_argument("--limit", type=int, default=20)
    list_cmd.add_argument(
        "--format",
        choices=["human", "tsv"],
        default="human",
        help="human: numbered lines for humans; tsv: KEY\\tISO8601\\tBASENAME for scripts",
    )

    download = subparsers.add_parser("download", help="Download a bundle from S3")
    download.add_argument("--key", required=True)
    download.add_argument("--output", type=Path, required=True)

    return parser.parse_args(argv)


def main(argv: Optional[List[str]] = None) -> int:
    args = parse_args(argv)

    if args.command == "upload":
        code = upload_backups(
            Path(args.backups_dir),
            args.prefix,
            args.name_prefix or backup_name_prefix(),
            args.max_age_hours,
        )
        return code

    if args.command == "list":
        try:
            items = list_backup_items(args.prefix, args.limit)
        except SystemExit:
            raise
        except Exception as exc:  # pragma: no cover - S3 connectivity
            print(f"Failed to list S3 backups: {exc}", file=sys.stderr)
            return 2

        if args.format == "tsv":
            for key, lm, basename in items:
                print(f"{key}\t{lm.isoformat()}\t{basename}")
            return 0

        if not items:
            print("No backup bundles found in S3.", file=sys.stderr)
            return 1
        for idx, (key, lm, basename) in enumerate(items, start=1):
            print(f"{idx}\t{basename}\t{lm.isoformat()}\t{key}")
        return 0

    if args.command == "download":
        download_backup(args.key, args.output)
        return 0

    return 1


if __name__ == "__main__":
    raise SystemExit(main())

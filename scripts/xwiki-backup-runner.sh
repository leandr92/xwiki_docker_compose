#!/bin/sh

set -e

BACKUP_INIT_SLEEP="${BACKUP_INIT_SLEEP:-30m}"
BACKUP_INTERVAL="${BACKUP_INTERVAL:-24h}"

XWIKI_BACKUPS_PATH="${XWIKI_BACKUPS_PATH:-/srv/xwiki/backups}"
DATA_PATH="${DATA_PATH:-/usr/local/xwiki}"
XWIKI_BACKUP_NAME="${XWIKI_BACKUP_NAME:-xwiki-backup}"
BACKUP_PRUNE_DAYS="${BACKUP_PRUNE_DAYS:-7}"

# Fixed member names inside each bundle archive.
BACKUP_POSTGRES_MEMBER="postgres.sql.gz"
BACKUP_DATA_MEMBER="application-data.tar.gz"

echo "xwiki-backup-runner: initial sleep for ${BACKUP_INIT_SLEEP}..."
sleep "${BACKUP_INIT_SLEEP}"

mkdir -p "${XWIKI_BACKUPS_PATH}"

while true; do
  TIMESTAMP="$(date '+%Y-%m-%d_%H-%M')"
  BUNDLE_FILE="${XWIKI_BACKUPS_PATH}/${XWIKI_BACKUP_NAME}-${TIMESTAMP}.tar.gz"
  WORKDIR="$(mktemp -d)"

  echo "xwiki-backup-runner: starting backup cycle at ${TIMESTAMP}"

  cleanup_workdir() {
    rm -rf "${WORKDIR}"
  }
  trap cleanup_workdir EXIT

  echo "xwiki-backup-runner: dumping PostgreSQL to ${WORKDIR}/${BACKUP_POSTGRES_MEMBER}"
  if ! pg_dump -h postgres -p 5432 -d "${XWIKI_DB_NAME}" -U "${XWIKI_DB_USER}" | gzip > "${WORKDIR}/${BACKUP_POSTGRES_MEMBER}"; then
    echo "xwiki-backup-runner: PostgreSQL backup failed, skipping cycle" >&2
    cleanup_workdir
    trap - EXIT
    sleep "${BACKUP_INTERVAL}"
    continue
  fi

  echo "xwiki-backup-runner: archiving application data to ${WORKDIR}/${BACKUP_DATA_MEMBER}"
  if ! tar -zcpf "${WORKDIR}/${BACKUP_DATA_MEMBER}" "${DATA_PATH}"; then
    echo "xwiki-backup-runner: application data backup failed, skipping cycle" >&2
    cleanup_workdir
    trap - EXIT
    sleep "${BACKUP_INTERVAL}"
    continue
  fi

  echo "xwiki-backup-runner: creating bundle ${BUNDLE_FILE}"
  if ! tar -zcf "${BUNDLE_FILE}" -C "${WORKDIR}" "${BACKUP_POSTGRES_MEMBER}" "${BACKUP_DATA_MEMBER}"; then
    echo "xwiki-backup-runner: failed to create bundle archive" >&2
    cleanup_workdir
    trap - EXIT
    sleep "${BACKUP_INTERVAL}"
    continue
  fi

  cleanup_workdir
  trap - EXIT

  if [ -n "${S3_BUCKET_NAME:-}" ]; then
    echo "xwiki-backup-runner: uploading bundle to S3"
    if ! python3 /scripts/xwiki_backup_to_s3.py upload --backups-dir "${XWIKI_BACKUPS_PATH}"; then
      echo "xwiki-backup-runner: S3 upload failed" >&2
    fi
  else
    echo "xwiki-backup-runner: S3_BUCKET_NAME not set, skipping S3 upload"
  fi

  echo "xwiki-backup-runner: pruning old local bundles"
  find "${XWIKI_BACKUPS_PATH}" -type f -name "${XWIKI_BACKUP_NAME}-*.tar.gz" -mtime +"${BACKUP_PRUNE_DAYS}" -delete || true

  echo "xwiki-backup-runner: sleeping for ${BACKUP_INTERVAL}"
  sleep "${BACKUP_INTERVAL}"
done

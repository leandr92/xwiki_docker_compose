#!/usr/bin/env bash

# Restores database and application data from a unified XWiki backup bundle.
# Interactive menu: numbered local bundles and S3 bundles (download then restore).

set -euo pipefail

BACKUP_POSTGRES_MEMBER="postgres.sql.gz"
BACKUP_DATA_MEMBER="application-data.tar.gz"
S3_LIST_LIMIT="${S3_LIST_LIMIT:-30}"

XWIKI_CONTAINER=$(docker ps -aqf "name=xwiki-xwiki" | head -n 1)
XWIKI_BACKUPS_CONTAINER=$(docker ps -aqf "name=xwiki-backups" | head -n 1)

if [ -z "${XWIKI_CONTAINER}" ] || [ -z "${XWIKI_BACKUPS_CONTAINER}" ]; then
  echo "Error: xwiki or backups container not found. Is the stack running?" >&2
  exit 1
fi

DATA_PATH=$(docker exec "${XWIKI_BACKUPS_CONTAINER}" printenv DATA_PATH 2>/dev/null || echo "/usr/local/xwiki")
BACKUP_DIR=$(docker exec "${XWIKI_BACKUPS_CONTAINER}" printenv XWIKI_BACKUPS_PATH 2>/dev/null || echo "/srv/xwiki/backups")
BACKUP_DIR="${BACKUP_DIR%/}"

XWIKI_DB_NAME=$(docker exec "${XWIKI_BACKUPS_CONTAINER}" printenv XWIKI_DB_NAME)
XWIKI_DB_USER=$(docker exec "${XWIKI_BACKUPS_CONTAINER}" printenv XWIKI_DB_USER)
S3_BUCKET_NAME=$(docker exec "${XWIKI_BACKUPS_CONTAINER}" printenv S3_BUCKET_NAME 2>/dev/null || true)

MENU_DIR=$(mktemp -d)
trap 'rm -rf "${MENU_DIR}"' EXIT

LOCAL_NAMES="${MENU_DIR}/local.names"
LOCAL_MTIMES="${MENU_DIR}/local.mtimes"
S3_KEYS="${MENU_DIR}/s3.keys"
S3_MTIMES="${MENU_DIR}/s3.mtimes"
S3_NAMES="${MENU_DIR}/s3.names"
> "${LOCAL_NAMES}"
> "${S3_KEYS}"

docker exec "${XWIKI_BACKUPS_CONTAINER}" sh -ec "
  set -- ${BACKUP_DIR}/*.tar.gz
  if [ ! -e \"\$1\" ]; then
    exit 0
  fi
  for f in \$(ls -1t ${BACKUP_DIR}/*.tar.gz); do
    printf '%s\n' \"\$(basename \"\$f\")\"
    stat -c '%Y' \"\$f\" 2>/dev/null || echo 0
  done
" > "${MENU_DIR}/local.raw" 2>/dev/null || true

if [ -s "${MENU_DIR}/local.raw" ]; then
  awk 'NR % 2 == 1' "${MENU_DIR}/local.raw" > "${LOCAL_NAMES}"
  awk 'NR % 2 == 0' "${MENU_DIR}/local.raw" > "${LOCAL_MTIMES}"
fi

S3_CONFIGURED=0
if [ -n "${S3_BUCKET_NAME}" ]; then
  S3_CONFIGURED=1
  S3_LIST_EXIT=0
  docker exec "${XWIKI_BACKUPS_CONTAINER}" python3 /scripts/xwiki_backup_to_s3.py list \
    --format tsv --limit "${S3_LIST_LIMIT}" > "${MENU_DIR}/s3.tsv" 2>/dev/null || S3_LIST_EXIT=$?
  if [ "${S3_LIST_EXIT}" -eq 0 ] && [ -s "${MENU_DIR}/s3.tsv" ]; then
    while IFS=$'\t' read -r key modified basename; do
      [ -n "${key}" ] || continue
      echo "${key}" >> "${S3_KEYS}"
      echo "${modified}" >> "${S3_MTIMES}"
      echo "${basename}" >> "${S3_NAMES}"
    done < "${MENU_DIR}/s3.tsv"
  elif [ "${S3_LIST_EXIT}" -ne 0 ]; then
    S3_CONFIGURED=2
  fi
fi

LOCAL_COUNT=0
S3_COUNT=0
[ -f "${LOCAL_NAMES}" ] && LOCAL_COUNT=$(wc -l < "${LOCAL_NAMES}" | tr -d ' ')
[ -f "${S3_KEYS}" ] && S3_COUNT=$(wc -l < "${S3_KEYS}" | tr -d ' ')
TOTAL=$((LOCAL_COUNT + S3_COUNT))

format_mtime() {
  local epoch="${1:-0}"
  if [ "${epoch}" = "0" ]; then
    echo "unknown date"
    return
  fi
  if date -r "${epoch}" '+%Y-%m-%d %H:%M %Z' 2>/dev/null; then
    return
  fi
  date -d "@${epoch}" '+%Y-%m-%d %H:%M %Z' 2>/dev/null || echo "epoch ${epoch}"
}

print_menu() {
  echo ""
  echo "=== Backups on disk (restore directly) ==="
  if [ "${LOCAL_COUNT}" -eq 0 ]; then
    echo "  (none)"
  else
    local i=1
    while [ "${i}" -le "${LOCAL_COUNT}" ]; do
      name=$(sed -n "${i}p" "${LOCAL_NAMES}")
      mtime_epoch=$(sed -n "${i}p" "${LOCAL_MTIMES}")
      printf "  %2d  [local]  %s  (%s)\n" "${i}" "${name}" "$(format_mtime "${mtime_epoch}")"
      i=$((i + 1))
    done
  fi

  echo ""
  echo "=== Backups in S3 (download, then restore) ==="
  if [ "${S3_CONFIGURED}" -eq 0 ]; then
    echo "  (S3_BUCKET_NAME is not set)"
  elif [ "${S3_CONFIGURED}" -eq 2 ]; then
    echo "  (could not list S3 — check credentials and network)"
  elif [ "${S3_COUNT}" -eq 0 ]; then
    echo "  (none)"
  else
    local i=1
  local n=$((LOCAL_COUNT + 1))
    while [ "${i}" -le "${S3_COUNT}" ]; do
      name=$(sed -n "${i}p" "${S3_NAMES}")
      modified=$(sed -n "${i}p" "${S3_MTIMES}")
      key=$(sed -n "${i}p" "${S3_KEYS}")
      printf "  %2d  [s3]     %s  (%s)\n" "${n}" "${name}" "${modified}"
      printf "           s3://%s/%s\n" "${S3_BUCKET_NAME}" "${key}"
      i=$((i + 1))
      n=$((n + 1))
    done
  fi
  echo ""
}

restore_bundle() {
  local bundle_name="$1"
  local bundle_path="${BACKUP_DIR}/${bundle_name}"

  echo "--> Stopping XWiki..."
  docker stop "${XWIKI_CONTAINER}"

  echo "--> Restoring from ${bundle_name} (database + application data)..."
  docker exec "${XWIKI_BACKUPS_CONTAINER}" sh -ec "
    set -e
    BUNDLE='${bundle_path}'
    WORK=\$(mktemp -d)
    trap 'rm -rf \"\$WORK\"' EXIT
    test -f \"\$BUNDLE\"
    tar -zxf \"\$BUNDLE\" -C \"\$WORK\"
    test -f \"\$WORK/${BACKUP_POSTGRES_MEMBER}\"
    test -f \"\$WORK/${BACKUP_DATA_MEMBER}\"
    dropdb -h postgres -p 5432 '${XWIKI_DB_NAME}' -U '${XWIKI_DB_USER}' --if-exists
    createdb -h postgres -p 5432 '${XWIKI_DB_NAME}' -U '${XWIKI_DB_USER}'
    gunzip -c \"\$WORK/${BACKUP_POSTGRES_MEMBER}\" | psql -h postgres -p 5432 '${XWIKI_DB_NAME}' -U '${XWIKI_DB_USER}'
    rm -rf '${DATA_PATH}'/*
    tar -zxpf \"\$WORK/${BACKUP_DATA_MEMBER}\" -C /
  "

  echo "--> Restore completed."
  echo "--> Starting XWiki..."
  docker start "${XWIKI_CONTAINER}"
}

download_from_s3() {
  local s3_key="$1"
  local bundle_name="$2"
  local output_path="${BACKUP_DIR}/${bundle_name}"

  echo "--> Downloading s3://${S3_BUCKET_NAME}/${s3_key} ..."
  docker exec "${XWIKI_BACKUPS_CONTAINER}" python3 /scripts/xwiki_backup_to_s3.py download \
    --key "${s3_key}" \
    --output "${output_path}"
}

if [ "${TOTAL}" -eq 0 ]; then
  echo "No backup bundles found locally or in S3." >&2
  exit 1
fi

print_menu

CHOICE="${1:-}"
if [ -z "${CHOICE}" ]; then
  echo "Enter backup number to restore (1-${TOTAL}), or q to quit:"
  read -r CHOICE
fi

case "${CHOICE}" in
  q|Q) echo "Cancelled."; exit 0 ;;
esac

if ! [[ "${CHOICE}" =~ ^[0-9]+$ ]] || [ "${CHOICE}" -lt 1 ] || [ "${CHOICE}" -gt "${TOTAL}" ]; then
  echo "Error: enter a number from 1 to ${TOTAL}." >&2
  exit 1
fi

SELECTED_BUNDLE=""
SELECTED_SOURCE=""

if [ "${CHOICE}" -le "${LOCAL_COUNT}" ]; then
  SELECTED_SOURCE="local"
  SELECTED_BUNDLE=$(sed -n "${CHOICE}p" "${LOCAL_NAMES}")
else
  SELECTED_SOURCE="s3"
  S3_INDEX=$((CHOICE - LOCAL_COUNT))
  S3_KEY=$(sed -n "${S3_INDEX}p" "${S3_KEYS}")
  SELECTED_BUNDLE=$(sed -n "${S3_INDEX}p" "${S3_NAMES}")
fi

echo ""
echo "--> Selected: ${SELECTED_BUNDLE} [${SELECTED_SOURCE}]"
printf "Continue? This replaces the current database and wiki files. [y/N] "
read -r CONFIRM
case "${CONFIRM}" in
  y|Y|yes|YES) ;;
  *) echo "Cancelled."; exit 0 ;;
esac

if [ "${SELECTED_SOURCE}" = "s3" ]; then
  download_from_s3 "${S3_KEY}" "${SELECTED_BUNDLE}"
fi

restore_bundle "${SELECTED_BUNDLE}"

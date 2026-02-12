#!/usr/bin/env bash
# xwiki-logs.sh — сбор и просмотр логов XWiki в контейнере
set -euo pipefail

CONTAINER="${CONTAINER:-xwiki-xwiki-1}"
PATTERN="${1:-index|task|consumer|llm|mention|links|executor|timeout|rejected|error|exception}"
SINCE="${2:-1h}"
TAIL_N="${3:-500}"

echo "==[ docker logs (since=$SINCE, tail=$TAIL_N) ]==============================="
docker logs --since "$SINCE" --tail "$TAIL_N" "$CONTAINER" 2>&1 | tee /tmp/xwiki_docker_logs.txt

echo
echo "==[ в контейнере: tail важных файлов ]======================================"
docker exec "$CONTAINER" bash -lc '
set -e
FILES=(
  /usr/local/tomcat/logs/xwiki.log
  /var/lib/xwiki/data/logs/xwiki.log
  /usr/local/tomcat/logs/catalina.out
)
for f in "${FILES[@]}"; do
  if [ -f "$f" ]; then
    echo "-- $f -------------------------------------------------------------"
    tail -n '"$TAIL_N"' "$f" || true
  fi
done
' | tee /tmp/xwiki_incontainer_tail.txt

echo
echo "==[ grep по паттерну: $PATTERN ]============================================"
docker exec "$CONTAINER" bash -lc '
set -e
FILES=(
  /usr/local/tomcat/logs/xwiki.log
  /var/lib/xwiki/data/logs/xwiki.log
  /usr/local/tomcat/logs/catalina.out
)
for f in "${FILES[@]}"; do
  if [ -f "$f" ]; then
    echo "-- $f (grep) ------------------------------------------------------"
    grep -iE "'"$PATTERN"'" "$f" | tail -n '"$TAIL_N"' || true
  fi
done
' | tee /tmp/xwiki_grep.txt

echo
echo "==[ собрать архив логов (можно приложить к тикету) ]========================"
docker exec "$CONTAINER" bash -lc '
set -e
OUT=/tmp/xwiki-logs-$(date +%Y%m%d-%H%M%S).tgz
tar czf "$OUT" /usr/local/tomcat/logs 2>/dev/null || true
[ -f /var/lib/xwiki/data/logs/xwiki.log ] && tar rzvf "$OUT" /var/lib/xwiki/data/logs/xwiki.log 2>/dev/null || true
echo "$OUT"
' > /tmp/xwiki_logs_path.txt

ARCHIVE_PATH_IN_CONTAINER="$(tail -n1 /tmp/xwiki_logs_path.txt)"
if [[ -n "$ARCHIVE_PATH_IN_CONTAINER" && "$ARCHIVE_PATH_IN_CONTAINER" == /tmp/* ]]; then
  HOST_ARCHIVE="xwiki-logs-$(date +%Y%m%d-%H%M%S).tgz"
  docker cp "$CONTAINER:$ARCHIVE_PATH_IN_CONTAINER" "./$HOST_ARCHIVE" || true
  echo "Архив логов скопирован на хост: $HOST_ARCHIVE"
else
  echo "Не удалось упаковать/найти архив в контейнере."
fi

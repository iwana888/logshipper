#!/bin/bash
set -u
cd /mnt/e/Git/logshipper

# regenerate test log with CURRENT timestamps so Loki accepts them
NOW=$(date '+%Y-%m-%d %H:%M:%S')
MS=$(date +%s)000
printf '[INFO] %s first line\n[ERROR] %s second line\n[WARN] %s third line\n%s unix ms line\nplain line without timestamp\n' "$NOW" "$NOW" "$NOW" "$MS" > test/logs/app.log

# build linux binary
fpc -Mobjfpc -Sh -O2 -Fu. logshipper.lpr >/dev/null 2>&1

rm -f test/positions_real.json
./logshipper logshipper_real.ini > real_run.txt 2>&1 &
SHIP=$!
sleep 3
kill -TERM "$SHIP" 2>/dev/null
sleep 1
kill -9 "$SHIP" 2>/dev/null

echo "=== RUN LOG ==="
cat real_run.txt
echo "=== QUERY LOKI (job=logshipper-smoketest) ==="
START=$(( $(date +%s) - 3600 ))000000000
END=$(( $(date +%s) + 600 ))000000000
curl -sS -G http://localhost:3100/loki/api/v1/query_range \
  --data-urlencode 'query={job="logshipper-smoketest"}' \
  --data-urlencode "start=$START" \
  --data-urlencode "end=$END" | head -c 3000
echo

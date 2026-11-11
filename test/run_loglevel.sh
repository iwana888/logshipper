#!/bin/bash
# Verify log_file_level: console stays full, file is filtered.
# One stateless "bad" mock (HTTP 400) is reused across cases -> the shipper
# emits a real [ERROR] dropping batch line on every push.
set -u
cd /mnt/e/Git/logshipper
pkill -9 -x logshipper 2>/dev/null; pkill -9 -f mock_loki 2>/dev/null; sleep 1

(python3 test/mock_loki.py bad 59999 > mock_out.txt 2>&1 &)
sleep 1

run_case() {
  local label="$1" level_line="$2" out="$3"
  pkill -9 -x logshipper 2>/dev/null; sleep 0.3
  rm -f "$out" test/pos_lvl.json run_out.txt mock_received.tmp
  printf '[INFO] 2026-11-04 14:00:00 level test line one\n[ERROR] 2026-11-04 14:00:01 level test line two\n[INFO] 2026-11-04 14:00:02 this line is deliberately far longer than max_line_bytes so it triggers a WARN truncation notice\n' > test/logs/app.log
  cat > /tmp/lvl.ini <<EOF
[loki]
url=http://127.0.0.1:59999/loki/api/v1/push
gzip=true
timeout_ms=2000
[agent]
job=myapp
instance=test-1
poll_interval_ms=200
batch_max_lines=5
batch_max_delay_ms=1000
buffer_max_lines=10000
log_file=$out
$level_line
[files]
paths=test/logs/*.log
positions_file=test/pos_lvl.json
max_line_bytes=60
[timestamp]
formats=%Y-%m-%d %H:%M:%S;unix_ms
EOF
  timeout 4 ./logshipper /tmp/lvl.ini > run_out.txt 2>&1
  echo "=== $label ==="
  echo "  file   INFO / WARN / ERROR : $(grep -c '\[INFO\]' "$out" || true) / $(grep -c '\[WARN\]' "$out" || true) / $(grep -c '\[ERROR\]' "$out" || true)"
  echo "  console INFO / ERROR       : $(grep -c '\[INFO\]' run_out.txt || true) / $(grep -c '\[ERROR\]' run_out.txt || true)"
}

run_case "default (expect only ERROR in file)"  "; no log_file_level -> default error"  agent_default.log
run_case "log_file_level=warn"                  "log_file_level=warn"                agent_warn.log
run_case "log_file_level=info"                  "log_file_level=info"                agent_info.log

echo "=== mock pushes (400) ==="
grep -c 'MOCK rc=400' mock_out.txt || true
echo "=== sample of default file ==="
cat agent_default.log
pkill -9 -f mock_loki 2>/dev/null
rm -f agent_default.log agent_warn.log agent_info.log test/pos_lvl.json /tmp/lvl.ini

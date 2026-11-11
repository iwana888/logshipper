#!/bin/bash
# Verify the shipper's own status log lands in log_file, rotates, and is NOT
# tailed back in (feedback loop). We place the agent log in the tailed dir with
# a .log extension to prove the exclusion works.
set -u
cd /mnt/e/Git/logshipper
pkill -9 -x logshipper 2>/dev/null; pkill -9 -f mock_loki 2>/dev/null; sleep 1

cat > /tmp/agent.ini <<'EOF'
[loki]
url=http://127.0.0.1:59999/loki/api/v1/push
gzip=true
timeout_ms=2000
[agent]
job=myapp
instance=test-1
poll_interval_ms=200
batch_max_lines=5
batch_max_bytes=262144
batch_max_delay_ms=1000
buffer_max_lines=10000
log_file=test/logs/logshipper.log
log_file_max_bytes=300
log_file_max_files=3
[files]
paths=test/logs/*.log
timestamp/formats=%Y-%m-%d %H:%M:%S;unix_ms
EOF

printf '[INFO] 2026-11-04 14:00:00 app line one\n[ERROR] 2026-11-04 14:00:01 app line two\n' > test/logs/app.log
rm -f test/logs/logshipper.log test/logs/logshipper.log.* mock_out.txt mock_received.tmp run_out.txt test/positions.json
(python3 test/mock_loki.py ok 59999 > mock_out.txt 2>&1 &)
sleep 1
# Grow the app log so the shipper emits many "pushed N lines" status lines -> rotation.
for i in $(seq 1 30); do echo "[INFO] 2026-11-04 14:00:0$i repeated app log line to grow the agent log via pushed messages $i" >> test/logs/app.log; done
timeout 6 ./logshipper /tmp/agent.ini > run_out.txt 2>&1
pkill -9 -f mock_loki 2>/dev/null

echo "=== agent log files (rotation) ==="
ls -la test/logs/logshipper.log* 2>/dev/null
echo "=== head of agent log (should be shipper status, NOT app lines) ==="
head -15 test/logs/logshipper.log
echo "=== shipper-status lines leaked into Loki as app logs? (expect 0) ==="
grep -c 'logshipper starting\|pushed N lines' mock_out.txt || true
echo "=== app lines actually received by Loki ==="
grep -o 'first=\[' mock_out.txt | wc -l
rm -f test/logs/logshipper.log test/logs/logshipper.log.* /tmp/agent.ini

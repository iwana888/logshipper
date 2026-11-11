#!/bin/bash
# Validates the sender thread pool actually parallelizes pushes.
# Generates a burst of log lines, runs logshipper with N sender threads against a
# threaded mock Loki in "slow" mode (0.4s/request), and prints the max observed
# concurrent POSTs. CONC_MAX == N proves N senders push in parallel.
set -u
cd /mnt/e/Git/logshipper

N="${1:-2}"

pkill -9 -f mock_loki 2>/dev/null || true
pkill -9 -x logshipper 2>/dev/null || true
sleep 1

# 3000-line burst so the queue fills with many batches.
python3 - <<'PY'
with open('test/logs/app.log','w') as f:
    for i in range(3000):
        f.write("[INFO] 2026-11-04 11:00:00 burst line %d some payload text here\n" % i)
PY

rm -f test/positions.json mock_out.txt mock_received.tmp run_out.txt
cat > /tmp/sh_pool.ini <<EOF
[loki]
url=http://127.0.0.1:59999/loki/api/v1/push
token=
gzip=true
timeout_ms=5000
[agent]
job=myapp
instance=test-1
poll_interval_ms=20
batch_max_lines=20
batch_max_bytes=262144
batch_max_delay_ms=2000
buffer_max_lines=20000
sender_threads=$N
[files]
paths=test/logs/app.log
positions_file=test/positions.json
max_line_bytes=262144
[timestamp]
formats=%Y-%m-%d %H:%M:%S;unix_ms
tz=local
level_regex=\[(INFO|WARN|ERROR|DEBUG)\]
EOF

echo "=== sender_threads=$N, starting mock (slow) ==="
(python3 test/mock_loki.py slow 59999 > mock_out.txt 2>&1 &)
sleep 1
echo "=== running logshipper (graceful timeout) ==="
timeout 20 ./logshipper /tmp/sh_pool.ini > run_out.txt 2>&1
echo "logshipper exit: $?"
pkill -9 -f mock_loki 2>/dev/null

echo "=== MAX CONCURRENT POSTs (expect $N) ==="
grep -o 'CONC_MAX=[0-9]*' mock_out.txt | sort -t= -k2 -n | tail -1
echo "=== batches pushed ==="
grep -c 'pushed' run_out.txt
echo "=== first 3 pushed lines ==="
grep -E 'pushed' run_out.txt | head -3

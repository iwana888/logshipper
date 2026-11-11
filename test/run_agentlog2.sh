#!/bin/bash
# Show that the agent's own status log (heartbeat + lifecycle) lands in log_file,
# proving "is it running?" is answerable from the file even when the console is noisy.
set -u
cd /mnt/e/Git/logshipper
pkill -9 -x logshipper 2>/dev/null; pkill -9 -f mock_loki 2>/dev/null; sleep 1

cat > /tmp/agent2.ini <<'EOF'
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
log_file=agent_check.log
[files]
paths=test/logs/*.log
timestamp/formats=%Y-%m-%d %H:%M:%S;unix_ms
EOF

printf '[INFO] 2026-11-04 14:00:00 heartbeat check line\n' > test/logs/app.log
rm -f agent_check.log test/positions.json mock_out.txt run_out.txt
(python3 test/mock_loki.py ok 59999 > mock_out.txt 2>&1 &)
sleep 1
timeout 3 ./logshipper /tmp/agent2.ini > run_out.txt 2>&1
pkill -9 -f mock_loki 2>/dev/null
echo "=== agent_check.log (shipper's own status; heartbeat = 'pushed N lines') ==="
cat agent_check.log
rm -f agent_check.log /tmp/agent2.ini

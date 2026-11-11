#!/bin/bash
# Verify per-line timestamp clamping: a batch mixing a recent line and an
# out-of-window (old) line must NOT be dropped. The old line is reset to read-time
# ("now") so it still ingests; the recent line keeps its real timestamp.
set -u
cd /mnt/e/Git/logshipper
pkill -9 -x logshipper 2>/dev/null || true
pkill -9 -f mock_loki 2>/dev/null || true
sleep 1
printf '[INFO] 2026-11-04 14:00:00 recent line within window\n[INFO] 2026-10-28 10:00:00 old line beyond 7 days (should clamp to now)\n' > test/logs/app.log
rm -f test/positions.json mock_out.txt mock_received.tmp run_out.txt
(python3 test/mock_loki.py ok 59999 > mock_out.txt 2>&1 &)
sleep 1
timeout 5 ./logshipper test/logshipper.ini > run_out.txt 2>&1
pkill -9 -f mock_loki 2>/dev/null || true
echo "=== shipper log (pushed / dropping / clamp warning) ==="
grep -E 'pushed|dropping|window reset' run_out.txt
echo "=== mock received ==="
cat mock_received.tmp
echo "=== pushed timestamps (old line should be ~now/1.7e18, recent should be ~14:00) ==="
grep -o '"values":\[\[[0-9]*' mock_out.txt | head

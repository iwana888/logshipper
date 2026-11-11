#!/bin/bash
# Regression test for the "leading-number line parsed as 1970 timestamp" bug.
# A line that begins with a number must now fall through to the "now" fallback
# (instead of getting a 1970 epoch and poisoning the whole batch with a Loki 400).
set -u
cd /mnt/e/Git/logshipper
pkill -9 -x logshipper 2>/dev/null || true
pkill -9 -f mock_loki 2>/dev/null || true
sleep 1
printf '[INFO] 2026-11-04 14:24:46 normal timestamped line\n20261000 this line starts with a number (was misparsed to 1970 before fix)\n[ERROR] 2026-11-04 14:24:47 another real line\n' > test/logs/app.log
rm -f test/positions.json mock_out.txt mock_received.tmp run_out.txt
(python3 test/mock_loki.py ok 59999 > mock_out.txt 2>&1 &)
sleep 1
timeout 5 ./logshipper test/logshipper.ini > run_out.txt 2>&1
pkill -9 -f mock_loki 2>/dev/null || true
echo "=== shipper log (pushed / dropping) ==="
grep -E 'pushed|dropping' run_out.txt
echo "=== mock received (rc) ==="
cat mock_received.tmp
echo "=== timestamps actually pushed (1970 would be ~2e13 ns; now is ~1.7e18) ==="
grep -o '"values":\[\[[0-9]*' mock_out.txt | head -3

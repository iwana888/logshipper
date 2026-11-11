#!/bin/bash
set -u
cd /mnt/e/Git/logshipper
pkill -9 -x logshipper 2>/dev/null || true
pkill -9 -f mock_loki 2>/dev/null || true
sleep 1
for M in ok bad retry; do
  echo "########## MODE=$M ##########"
  rm -f test/positions.json mock_out.txt mock_received.tmp run_out.txt
  (python3 test/mock_loki.py "$M" 59999 > mock_out.txt 2>&1 &)
  sleep 1
  timeout 6 ./logshipper test/logshipper.ini > run_out.txt 2>&1
  pkill -9 -f mock_loki 2>/dev/null || true
  echo "--- mock received (RECEIVED) ---"
  cat mock_received.tmp
  echo "--- shipper log ---"
  grep -E 'starting|started|pushed|dropping|retry|shutting|exit' run_out.txt | head -6
  echo
done

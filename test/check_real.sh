#!/bin/bash
set -u
cd /mnt/e/Git/logshipper
bash test/run_real.sh > /tmp/realout.txt 2>&1
echo "=== RUN (push result) ==="
grep -E 'pushed|dropping|ERROR|WARN' /tmp/realout.txt
echo "=== QUERY resultType ==="
grep -o '"resultType":"[^"]*"' /tmp/realout.txt | head -1
echo "=== how many streams returned ==="
grep -o '"stream":{' /tmp/realout.txt | wc -l
echo "=== sample line values ==="
grep -o '"values":\[\["[^]]*' /tmp/realout.txt | head -3

#!/bin/bash
# Characterise the real log file so batch/size settings can be judged on data.
set -u
F='/path/to/your/app/logs/app.log'
if [ ! -f "$F" ]; then F='./app.log'; fi
echo "file: $F"
ls -la --time-style=long-iso "$F"

echo "=== size now, then after 5s (write rate) ==="
S1=$(stat -c %s "$F"); sleep 5; S2=$(stat -c %s "$F")
echo "  size: $S1 -> $S2  delta=$((S2-S1)) bytes / 5s  => $(( (S2-S1)/5 )) B/s, $(( (S2-S1)*12 )) B/min approx"

echo "=== line-length distribution (whole file, bytes) ==="
python3 - "$F" <<'PY'
import sys
f=sys.argv[1]
n=0; total=0; mx=0; over={}
buckets={'<=256':0,'257-1K':0,'1K-4K':0,'4K-16K':0,'16K-64K':0,'64K-256K':0,'>256K':0}
lens=[]
with open(f,'rb') as fh:
    for line in fh:
        L=len(line.rstrip(b'\r\n'))
        n+=1; total+=L; mx=max(mx,L); lens.append(L)
        if L<=256: buckets['<=256']+=1
        elif L<=1024: buckets['257-1K']+=1
        elif L<=4096: buckets['1K-4K']+=1
        elif L<=16384: buckets['4K-16K']+=1
        elif L<=65536: buckets['16K-64K']+=1
        elif L<=262144: buckets['64K-256K']+=1
        else: buckets['>256K']+=1
        for t in (256,1024,4096,16384,65536,262144):
            over[t]=over.get(t,0)+(1 if L>t else 0)
if not n:
    print('  (empty file)'); raise SystemExit
lens.sort()
def pct(p): return lens[min(n-1,int(n*p))]
print(f'  lines={n}  total={total}  avg={total//n} B')
print(f'  p50={pct(.50)}  p90={pct(.90)}  p95={pct(.95)}  p99={pct(.99)}  max={mx} B')
print('  buckets:')
for k,v in buckets.items(): print(f'    {k:10s}: {v}')
print('  lines over threshold (would be TRUNCATED at that max_line_bytes):')
for t in sorted(over): print(f'    >{t:7d} B : {over[t]} lines ({over[t]*100/n:.3f}%)')
print(f'  at 100 lines/batch, avg batch payload ~= {total//n*100} B (gzip much less)')
PY

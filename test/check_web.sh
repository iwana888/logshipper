#!/bin/bash
# Start the viewer proxy on :8099 and verify page + proxied Loki API.
set -u
cd "$(dirname "$0")/.."
pkill -9 -f 'web/serve.py' 2>/dev/null; sleep 0.5
python3 web/serve.py --port 8099 > /tmp/web_srv.log 2>&1 &
sleep 1.2

echo "=== server log ==="
cat /tmp/web_srv.log
echo "=== GET / (page) ==="
curl -s -o /tmp/page.html -w 'status=%{http_code} bytes=%{size_download}\n' http://127.0.0.1:8099/
grep -o '<title>[^<]*</title>' /tmp/page.html
echo "=== GET /api/info ==="
curl -s http://127.0.0.1:8099/api/info
echo
echo "=== proxied label values ==="
curl -s http://127.0.0.1:8099/loki/api/v1/label/job/values
echo
echo "=== proxied query_range (same LogQL the page builds) ==="
END=$(date +%s); START=$((END-3600))
curl -s --get http://127.0.0.1:8099/loki/api/v1/query_range \
  --data-urlencode 'query={job="myapp"}' \
  --data-urlencode "start=${START}000000000" \
  --data-urlencode "end=${END}000000000" \
  --data-urlencode 'limit=3' \
  --data-urlencode 'direction=backward' | head -c 600
echo
echo "=== proxied keyword query ==="
curl -s --get http://127.0.0.1:8099/loki/api/v1/query_range \
  --data-urlencode 'query={job="myapp"} |= "HealthCheck"' \
  --data-urlencode "start=${START}000000000" \
  --data-urlencode "end=${END}000000000" \
  --data-urlencode 'limit=2' | head -c 300
echo
echo "=== CORS header present? ==="
curl -s -D - -o /dev/null -H 'Origin: http://example.com' \
  http://127.0.0.1:8099/loki/api/v1/label/job/values | grep -i 'access-control-allow-origin'
echo "=== 404 handling ==="
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8099/nope
pkill -9 -f 'web/serve.py' 2>/dev/null
rm -f /tmp/page.html /tmp/web_srv.log

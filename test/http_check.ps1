$root = 'E:\Git\logshipper'
$dir  = Join-Path $root 'test\http'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$enc  = New-Object System.Text.UTF8Encoding($false)

$mock = Join-Path $dir 'mock.py'
@'
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def _s(self, c, b=b''):
        self.send_response(c); self.send_header('Content-Type','application/json')
        self.send_header('Content-Length', str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        print('MOCK GOT:', self.path, flush=True)
        if self.path.startswith('/loki/'):
            body = b'{"status":"success","proxied_path":"' + self.path.encode() + b'"}'
            self._s(200, body)
        else:
            self._s(200, b'{"status":"ok"}')
    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0)); self.rfile.read(n); self._s(204)
    def log_message(self, *a): pass
ThreadingHTTPServer(('127.0.0.1', 18123), H).serve_forever()
'@ | Set-Content -Path $mock -Encoding UTF8
$mockP = Start-Process -FilePath python -ArgumentList @($mock) -WorkingDirectory $dir `
  -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $dir 'mock.out') `
  -RedirectStandardError (Join-Path $dir 'mock.err')
Start-Sleep -Milliseconds 600

$ini = Join-Path $dir 'http.ini'
@"
[loki]
url=http://127.0.0.1:18123/loki/api/v1/push

[agent]
job=myapp
instance=app-1
log_file=
log_file_level=

[files]
paths=$dir\app.log
positions_file=$dir\positions.json

[timestamp]
max_age_hours=168

[http]
listen=127.0.0.1:8099
"@ | Set-Content -Path $ini -Encoding UTF8

[System.IO.File]::WriteAllLines((Join-Path $dir 'app.log'), @('2026-11-05 17:00:00 "4 info  [t] line1'), $enc)

$log = Join-Path $dir 'ship.out'
$err = Join-Path $dir 'ship.err'
$p = Start-Process -FilePath (Join-Path $root 'logshipper.exe') -ArgumentList @($ini) `
  -WorkingDirectory $root -RedirectStandardOutput $log -RedirectStandardError $err `
  -PassThru -NoNewWindow
Start-Sleep -Seconds 3

function C($u) {
  try { & curl.exe -s -i $u } catch { 'CURL_ERR: ' + $_.Exception.Message }
}

Write-Output '--- GET / (first 3 lines) ---'
(& curl.exe -s 'http://127.0.0.1:8099/' | Select-Object -First 3)
Write-Output '--- GET /api/info ---'
C 'http://127.0.0.1:8099/api/info'
Write-Output '--- GET /loki/api/v1/query_range (raw status line + body) ---'
C 'http://127.0.0.1:8099/loki/api/v1/query_range?query=%7Bjob%3D%22myapp%22%7D'
Write-Output '--- POST /loki/api/v1/push (raw status line + body) ---'
C -Method Post -Body '{"streams":[]}' 'http://127.0.0.1:8099/loki/api/v1/push'
Write-Output '--- path seen by mock Loki ---'
Get-Content (Join-Path $dir 'mock.out') -ErrorAction SilentlyContinue

Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 300
Stop-Process -Id $mockP.Id -Force -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue

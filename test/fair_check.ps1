$ErrorActionPreference = 'Continue'
$root = 'E:\Git\logshipper'
$dir  = Join-Path $root 'test\fair'
$enc  = New-Object System.Text.UTF8Encoding($false)
$port = 18123
Set-Location $root
New-Item -ItemType Directory -Force -Path $dir | Out-Null

# Local Loki stand-in: append every pushed JSON body as one line so we can see
# exactly which instance appeared in which request (fairness evidence).
$receiver = Join-Path $dir 'receiver.py'
$requests = Join-Path $dir 'requests.jsonl'
@'
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

out, port = sys.argv[1], int(sys.argv[2])

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        with open(out, 'a', encoding='utf-8') as f:
            f.write(body.decode('utf-8', 'replace').replace('\n', ' ') + '\n')
        self.send_response(204)
        self.end_headers()
    def log_message(self, *a):
        pass

HTTPServer(('127.0.0.1', port), H).serve_forever()
'@ | Set-Content -Path $receiver -Encoding UTF8

Remove-Item $requests -Force -ErrorAction SilentlyContinue
$recv = Start-Process -FilePath 'python' -ArgumentList @($receiver, $requests, "$port") `
  -WorkingDirectory $root -PassThru -NoNewWindow `
  -RedirectStandardOutput (Join-Path $dir 'recv.out') `
  -RedirectStandardError (Join-Path $dir 'recv.err')
$ready = $false
for ($i = 0; $i -lt 40; $i++) {
  try {
    $c = New-Object Net.Sockets.TcpClient
    $c.Connect('127.0.0.1', $port)
    $c.Close()
    $ready = $true
    break
  } catch { Start-Sleep -Milliseconds 150 }
}
Write-Output ('receiver ready = ' + $ready)
if (-not $ready) {
  Stop-Process -Id $recv.Id -Force -ErrorAction SilentlyContinue
  exit 1
}

# Three directories with the SAME file name; 01 has a big backlog.
$stamp  = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('yyyyMMdd HHmmss') + '00'
$dirs   = @('01', '02', '03')
$counts = @(20000, 3, 3)
$logFiles = @()
for ($d = 0; $d -lt 3; $d++) {
  $logDir = Join-Path $dir (Join-Path $dirs[$d] 'logs')
  New-Item -ItemType Directory -Force -Path $logDir | Out-Null
  $logFile = Join-Path $logDir 'server.log'
  $logFiles += $logFile
  $lines = for ($n = 1; $n -le $counts[$d]; $n++) {
    $stamp + '  "4 info  [fair] instance=' + $dirs[$d] + ' line=' + $n
  }
  [System.IO.File]::WriteAllLines($logFile, $lines, $enc)
}
$pathsValue = (($dirs | ForEach-Object { Join-Path $dir (Join-Path $_ 'logs\*.log') }) -join ';')
$instValue  = 'inst-01;inst-02;inst-03'

$cfg = Get-Content (Join-Path $root 'logshipper.ini')
$cfg = $cfg | ForEach-Object {
  if ($_ -match '^url=')                    { 'url=http://127.0.0.1:' + $port + '/loki/api/v1/push' }
  elseif ($_ -match '^gzip=')               { 'gzip=false' }
  elseif ($_ -match '^job=')                { 'job=faircheck' }
  elseif ($_ -match '^sender_threads=')     { 'sender_threads=1' }
  elseif ($_ -match '^batch_max_delay_ms=') { 'batch_max_delay_ms=300' }
  elseif ($_ -match '^paths=')              { 'paths=' + $pathsValue; 'instances=' + $instValue }
  elseif ($_ -match '^positions_file=')     { 'positions_file=test/fair/positions.json' }
  elseif ($_ -match '^log_file=')           { '; log_file disabled for fair check' }
  elseif ($_ -match '^log_file_level=')     { '; disabled' }
  else                                      { $_ }
}
$iniFile = Join-Path $dir 'fair.ini'
[System.IO.File]::WriteAllLines($iniFile, $cfg, $enc)
$posFile = Join-Path $root 'test\fair\positions.json'
Remove-Item $posFile -Force -ErrorAction SilentlyContinue

$out = Join-Path $dir 'ship.out'
$err = Join-Path $dir 'ship.err'
Remove-Item $out, $err -Force -ErrorAction SilentlyContinue
$p = Start-Process -FilePath (Join-Path $root 'logshipper.exe') -ArgumentList @($iniFile) `
  -WorkingDirectory $root -RedirectStandardOutput $out -RedirectStandardError $err `
  -PassThru -NoNewWindow
Start-Sleep -Seconds 8
Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 300
Stop-Process -Id $recv.Id -Force -ErrorAction SilentlyContinue

Write-Output '--- phase A: three directories / per-path instances / fairness ---'
$reqLines = @(Get-Content $requests -ErrorAction SilentlyContinue)
Write-Output ('requests = ' + $reqLines.Count)
$instCount = @{}
$firstSeen = @{}
$total = 0
for ($r = 0; $r -lt $reqLines.Count; $r++) {
  $body = $reqLines[$r] | ConvertFrom-Json
  foreach ($s in $body.streams) {
    $key = $s.stream.instance
    $n = $s.values.Count
    if (-not $instCount.ContainsKey($key)) { $instCount[$key] = 0; $firstSeen[$key] = $r + 1 }
    $instCount[$key] += $n
    $total += $n
  }
}
foreach ($k in ($instCount.Keys | Sort-Object)) {
  Write-Output ('  instance=' + $k + ' lines=' + $instCount[$k] + ' first_request=' + $firstSeen[$k])
}
Write-Output ('  total lines = ' + $total + ' (expected 20006)')
$shipLog = Get-Content $err -Raw -ErrorAction SilentlyContinue
Write-Output ('  WARN/ERROR = ' + ([regex]::Matches($shipLog, '\[WARN\]')).Count + '/' +
              ([regex]::Matches($shipLog, '\[ERROR\]')).Count)
$pos = Get-Content $posFile -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
Write-Output ('  positions entries = ' + $pos.files.Count)
foreach ($f in $pos.files) {
  $size = (Get-Item $f.path).Length
  Write-Output ('    ' + (Split-Path $f.path -Parent | Split-Path -Parent | Split-Path -Leaf) +
                ' offset=' + $f.offset + ' size=' + $size)
}
Write-Output ('  startup targets = ' + ([regex]::Matches($shipLog, 'target\[')).Count)
$phaseA = ($instCount.Count -eq 3) -and
          ($instCount['inst-01'] -eq 20000) -and
          ($instCount['inst-02'] -eq 3) -and
          ($instCount['inst-03'] -eq 3) -and
          ($firstSeen['inst-02'] -le 15) -and
          ($firstSeen['inst-03'] -le 15) -and
          ($pos.files.Count -eq 3)
Write-Output ('  PHASE_A = ' + $(if ($phaseA) { 'PASS' } else { 'FAIL' }))

# Phase B: mismatched instances/paths count must refuse to start.
Write-Output '--- phase B: reject mismatched instances ---'
$badCfg = $cfg | ForEach-Object { if ($_ -match '^instances=') { 'instances=only-one' } else { $_ } }
$badIni = Join-Path $dir 'bad.ini'
[System.IO.File]::WriteAllLines($badIni, $badCfg, $enc)
$badErr = Join-Path $dir 'bad.err'
Remove-Item $badErr -Force -ErrorAction SilentlyContinue
$bp = Start-Process -FilePath (Join-Path $root 'logshipper.exe') -ArgumentList @($badIni) `
  -WorkingDirectory $root -RedirectStandardOutput (Join-Path $dir 'bad.out') `
  -RedirectStandardError $badErr -PassThru -NoNewWindow
Start-Sleep -Seconds 2
Stop-Process -Id $bp.Id -Force -ErrorAction SilentlyContinue
$badText = Get-Content $badErr -Raw -ErrorAction SilentlyContinue
$rejected = $badText -match 'must have one entry per'
Write-Output ('  rejected = ' + $rejected)
Write-Output ('  PHASE_B = ' + $(if ($rejected) { 'PASS' } else { 'FAIL' }))

# Phase C: a missing directory must produce a throttled WARN, not silence.
Write-Output '--- phase C: missing directory warning ---'
$missCfg = $cfg | ForEach-Object {
  if ($_ -match '^paths=')     { 'paths=' + $pathsValue + ';' + (Join-Path $dir 'nosuch\logs\*.log') }
  elseif ($_ -match '^instances=') { 'instances=' + $instValue + ';inst-04' }
  else { $_ }
}
$missIni = Join-Path $dir 'miss.ini'
[System.IO.File]::WriteAllLines($missIni, $missCfg, $enc)
$missErr = Join-Path $dir 'miss.err'
Remove-Item $missErr -Force -ErrorAction SilentlyContinue
$mp = Start-Process -FilePath (Join-Path $root 'logshipper.exe') -ArgumentList @($missIni) `
  -WorkingDirectory $root -RedirectStandardOutput (Join-Path $dir 'miss.out') `
  -RedirectStandardError $missErr -PassThru -NoNewWindow
Start-Sleep -Seconds 2
Stop-Process -Id $mp.Id -Force -ErrorAction SilentlyContinue
$missText = Get-Content $missErr -Raw -ErrorAction SilentlyContinue
$warned = ($missText -match 'no files match') -and ($missText -match 'directory does not exist')
$warnCount = ([regex]::Matches($missText, 'no files match')).Count
Write-Output ('  warned = ' + $warned + ' (warn lines = ' + $warnCount + ', expect 1 = throttled)')
Write-Output ('  PHASE_C = ' + $(if ($warned -and ($warnCount -eq 1)) { 'PASS' } else { 'FAIL' }))
Write-Output ('remaining logshipper processes = ' +
              ((Get-Process -Name logshipper -ErrorAction SilentlyContinue | Measure-Object).Count))

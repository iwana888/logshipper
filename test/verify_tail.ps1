$ErrorActionPreference = 'Continue'
$root = 'E:\Git\logshipper'
$enc  = New-Object System.Text.UTF8Encoding($false)
$dir  = Join-Path $root 'test\tail_logs'
$log  = Join-Path $dir 'part.log'
$ini  = Join-Path $root 'test\tail.ini'
$pos  = Join-Path $root 'test\tail_pos.json'
$out  = Join-Path $root 'test\tail_out.txt'
$err  = Join-Path $root 'test\tail_err.txt'
Set-Location $root
Get-Process -Name logshipper -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.Id -Force }
Start-Sleep -Milliseconds 400

New-Item -ItemType Directory -Force -Path $dir | Out-Null
Remove-Item $pos,$out,$err -Force -ErrorAction SilentlyContinue
$t = [DateTimeOffset]::UtcNow.AddMinutes(-2)
$stamp = $t.ToString('yyyyMMdd HHmmss') + '00'
$job  = 'tailcheck_' + $t.ToString('HHmmss')
$pfx  = $stamp + '  "4 info  [tailcheck] '
$line1  = $pfx + 'LINE-1'
$line2a = $pfx + 'LINE-2-PART-A'
$line3  = $pfx + 'LINE-3'
$line4  = $pfx + 'LINE-4'

# Phase 1: one complete line + a HALF line (no trailing newline)
[System.IO.File]::WriteAllText($log, $line1 + "`n" + $line2a, $enc)

$cfg = Get-Content (Join-Path $root 'logshipper.ini')
$cfg = $cfg | ForEach-Object {
  if ($_ -match '^job=')                    { 'job=' + $job }
  elseif ($_ -match '^instance=')           { 'instance=tailcheck-1' }
  elseif ($_ -match '^sender_threads=')     { 'sender_threads=1' }
  elseif ($_ -match '^batch_max_delay_ms=') { 'batch_max_delay_ms=300' }
  elseif ($_ -match '^paths=')              { 'paths=E:\Git\logshipper\test\tail_logs\*.log' }
  elseif ($_ -match '^positions_file=')     { 'positions_file=test/tail_pos.json' }
  elseif ($_ -match '^log_file=')           { '; disabled for verify' }
  elseif ($_ -match '^log_file_level=')     { '; disabled for verify' }
  else                                      { $_ }
}
[System.IO.File]::WriteAllLines($ini, $cfg, $enc)

Write-Output ('=== start with HALF line at EOF, job=' + $job + ' ===')
$p = Start-Process -FilePath (Join-Path $root 'logshipper.exe') -ArgumentList @($ini) `
  -WorkingDirectory $root -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -NoNewWindow
Start-Sleep -Seconds 3
Write-Output '=== append rest of the half line + LINE-3 ==='
[System.IO.File]::AppendAllText($log, 'PART-B' + "`n" + $line3 + "`n", $enc)
Start-Sleep -Seconds 3
Write-Output '=== append LINE-4 ==='
[System.IO.File]::AppendAllText($log, $line4 + "`n", $enc)
Start-Sleep -Seconds 3
if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }

$txt = Get-Content $err -Raw -ErrorAction SilentlyContinue
$ms = [regex]::Matches($txt, 'pushed (\d+) lines')
$sum = 0
foreach ($m in $ms) { $sum += [int]$m.Groups[1].Value }
Write-Output ('batches=' + $ms.Count + '  lines_pushed=' + $sum + '  (expected 4)')
Write-Output ('WARN=' + ([regex]::Matches($txt,'\[WARN\]')).Count + '  ERROR=' + ([regex]::Matches($txt,'\[ERROR\]')).Count)
Select-String -Path $err -Pattern 'truncate|poll error|oversized' -ErrorAction SilentlyContinue |
  ForEach-Object { Write-Output ('  UNEXPECTED: ' + $_.Line) }
$pj = Get-Content $pos -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
Write-Output ('positions offset=' + $pj.files[0].offset + '  final file size=' + (Get-Item $log).Length + '  (must be equal)')

$end   = [DateTimeOffset]::UtcNow.AddMinutes(2).ToUnixTimeMilliseconds() * 1000000
$start = [DateTimeOffset]::UtcNow.AddMinutes(-10).ToUnixTimeMilliseconds() * 1000000
$uri = 'http://localhost:3100/loki/api/v1/query_range?query=' +
       [uri]::EscapeDataString('{job="' + $job + '"}') + "&start=$start&end=$end&limit=50"
try {
  $r = Invoke-RestMethod -Uri $uri -TimeoutSec 10
  Write-Output ('Loki streams=' + $r.data.result.Count)
  foreach ($s in $r.data.result) {
    Write-Output ('  level=' + $s.stream.level + ' entries=' + $s.values.Count)
    foreach ($v in $s.values) { Write-Output ('    ' + $v[1]) }
  }
} catch {
  Write-Output ('QUERY FAILED: ' + $_.Exception.Message)
}

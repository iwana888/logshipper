$ErrorActionPreference = 'Continue'
$root = 'E:\Git\logshipper'
$fpc  = 'd:\lazarus\fpc\3.2.2\bin\x86_64-win64\fpc.exe'
$dir  = Join-Path $root 'test\verify_logs'
$log  = Join-Path $dir 'sample.log'
$ini  = Join-Path $root 'test\verify_ts.ini'
$pos  = Join-Path $root 'test\verify_pos.json'
$out  = Join-Path $root 'test\verify_out.txt'
$err  = Join-Path $root 'test\verify_err.txt'
$enc  = New-Object System.Text.UTF8Encoding($false)

Write-Output '=== stop old logshipper processes ==='
Get-Process -Name logshipper -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.Id -Force }
Start-Sleep -Milliseconds 500

Write-Output '=== full rebuild (Windows FPC -B) ==='
Set-Location $root
& $fpc -B -Mobjfpc -Sh -O2 -Fu. logshipper.lpr 2>&1 |
  Select-String -Pattern 'Fatal|Error|lines compiled' | ForEach-Object { Write-Output ('  ' + $_.Line) }

Write-Output '=== write TSynLog sample lines with a 2-minute-old UTC timestamp ==='
New-Item -ItemType Directory -Force -Path $dir | Out-Null
Remove-Item $pos,$out,$err -Force -ErrorAction SilentlyContinue
$sampleTime = [DateTimeOffset]::UtcNow.AddMinutes(-2)
$job  = 'tscheck_' + $sampleTime.ToString('HHmmss')
$stamp = $sampleTime.ToString('yyyyMMdd HHmmss') + '00'
$lines = @(
  ($stamp + '  "4 info  [verify] hello info line'),
  ($stamp + '  ! EXC  [verify] exception line'),
  ($stamp + '  ! trace  [verify] trace line'),
  ($stamp + '  G info  [verify] second info line')
)
[System.IO.File]::WriteAllLines($log, $lines, $enc)
$lines | ForEach-Object { Write-Output ('  ' + $_) }
Write-Output ('  expected local ts = ' + $sampleTime.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss'))

Write-Output '=== derive verify ini from the REAL logshipper.ini (only isolation keys changed) ==='
$cfg = Get-Content (Join-Path $root 'logshipper.ini')
$cfg = $cfg | ForEach-Object {
  if ($_ -match '^job=')                    { 'job=' + $job }
  elseif ($_ -match '^instance=')           { 'instance=verify-1' }
  elseif ($_ -match '^sender_threads=')     { 'sender_threads=1' }
  elseif ($_ -match '^batch_max_delay_ms=') { 'batch_max_delay_ms=500' }
  elseif ($_ -match '^paths=')              { 'paths=E:\Git\logshipper\test\verify_logs\*.log' }
  elseif ($_ -match '^positions_file=')     { 'positions_file=test/verify_pos.json' }
  elseif ($_ -match '^log_file=')           { '; log_file disabled for verify' }
  elseif ($_ -match '^log_file_level=')     { '; log_file_level disabled for verify' }
  else                                      { $_ }
}
[System.IO.File]::WriteAllLines($ini, $cfg, $enc)
Get-Content $ini | Where-Object { $_ -match '^(formats|tz|level_regex|batch_max_lines|batch_max_bytes|max_line_bytes|max_age_hours)=' } |
  ForEach-Object { Write-Output ('  ' + $_) }

Write-Output '=== push to real Loki (6 s) ==='
$p = Start-Process -FilePath (Join-Path $root 'logshipper.exe') -ArgumentList @($ini) `
  -WorkingDirectory $root -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -NoNewWindow
Start-Sleep -Seconds 6
if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
$logText = Get-Content $err -Raw -ErrorAction SilentlyContinue
Write-Output ('  pushed batches : ' + ([regex]::Matches($logText,'pushed \d+ lines')).Count)
Write-Output ('  WARN lines     : ' + ([regex]::Matches($logText,'\[WARN\]')).Count)
Write-Output ('  ERROR lines    : ' + ([regex]::Matches($logText,'\[ERROR\]')).Count)
Select-String -Path $err -Pattern 'invalid level_regex|clamped|oversized|poll error' -ErrorAction SilentlyContinue |
  Select-Object -First 6 | ForEach-Object { Write-Output ('  ' + $_.Line) }
Write-Output ('  verify positions: ' + (Get-Content $pos -Raw -ErrorAction SilentlyContinue))

Write-Output ('=== query Loki for {job="' + $job + '"} ===')
$end   = [DateTimeOffset]::UtcNow.AddMinutes(2).ToUnixTimeMilliseconds() * 1000000
$start = [DateTimeOffset]::UtcNow.AddMinutes(-15).ToUnixTimeMilliseconds() * 1000000
$uri = 'http://localhost:3100/loki/api/v1/query_range?query=' +
       [uri]::EscapeDataString('{job="' + $job + '"}') + "&start=$start&end=$end&limit=100"
try {
  $r = Invoke-RestMethod -Uri $uri -TimeoutSec 10
  Write-Output ('  status=' + $r.status + '  streams=' + $r.data.result.Count)
  foreach ($s in $r.data.result) {
    $lv = $s.stream.level
    if (-not $lv) { $lv = '<none>' }
    Write-Output ('  stream level=' + $lv + '  entries=' + $s.values.Count)
    foreach ($v in $s.values) {
      $local = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]([int64]$v[0] / 1000000)).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
      Write-Output ('    ts_local=' + $local + '  line=' + $v[1])
    }
  }
} catch {
  Write-Output ('  QUERY FAILED: ' + $_.Exception.Message)
}

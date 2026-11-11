$ErrorActionPreference = 'Continue'
$root  = 'E:\Git\logshipper'
$fpc   = 'd:\lazarus\fpc\3.2.2\bin\x86_64-win64\fpc.exe'
$enc   = New-Object System.Text.UTF8Encoding($false)
$cores = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
Set-Location $root

Get-Process -Name logshipper -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.Id -Force }
Start-Sleep -Milliseconds 400
Write-Output '=== full rebuild ==='
& $fpc -B -Mobjfpc -Sh -O2 -Fu. logshipper.lpr 2>&1 |
  Select-String -Pattern 'Fatal|Error|lines compiled' | ForEach-Object { Write-Output ('  ' + $_.Line) }

function Measure-Run($label, $iniPath, $secs) {
  $out = Join-Path $root 'test\cpu_out.txt'
  $err = Join-Path $root 'test\cpu_err.txt'
  Remove-Item $out,$err -Force -ErrorAction SilentlyContinue
  $p = Start-Process -FilePath (Join-Path $root 'logshipper.exe') -ArgumentList @($iniPath) `
    -WorkingDirectory $root -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -NoNewWindow
  Start-Sleep -Milliseconds 1200
  $c1 = 0.0; $c2 = 0.0
  try { $p.Refresh(); $c1 = [double]$p.CPU } catch { }
  $t1 = Get-Date
  Start-Sleep -Seconds $secs
  try { $p.Refresh(); $c2 = [double]$p.CPU } catch { $c2 = $c1 }
  $t2 = Get-Date
  $dt = ($t2 - $t1).TotalSeconds
  if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
  $txt = Get-Content $err -Raw -ErrorAction SilentlyContinue
  $batches = ([regex]::Matches($txt, 'pushed \d+ lines')).Count
  $lines = 0
  foreach ($m in [regex]::Matches($txt, 'pushed (\d+) lines')) { $lines += [int]$m.Groups[1].Value }
  $single = ($c2 - $c1) / $dt * 100
  Write-Output ('=== ' + $label + ' ===')
  Write-Output ('  window={0:N1}s  batches={1}  lines={2}  cpu_seconds={3:N2}' -f $dt, $batches, $lines, ($c2 - $c1))
  Write-Output ('  CPU as 1 full core = {0:N1}%   |   of all {1} logical cores = {2:N2}%' -f $single, $cores, ($single / $cores))
  Write-Output ('  WARN={0}  ERROR={1}' -f ([regex]::Matches($txt,'\[WARN\]')).Count, ([regex]::Matches($txt,'\[ERROR\]')).Count)
}

Write-Output '=== A: steady state, YOUR real logshipper.ini ==='
Measure-Run 'A steady (real ini)' (Join-Path $root 'logshipper.ini') 10

Write-Output '=== B: backfill 30000 synthetic TSynLog lines, isolated job ==='
$dir = Join-Path $root 'test\cpu_logs'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$sampleTime = [DateTimeOffset]::UtcNow.AddMinutes(-3)
$stamp = $sampleTime.ToString('yyyyMMdd HHmmss') + '00'
$job = 'cpucheck_' + $sampleTime.ToString('HHmmss')
$sb = New-Object System.Text.StringBuilder
for ($i = 0; $i -lt 30000; $i++) {
  [void]$sb.AppendLine($stamp + '  "4 info  [cpucheck] line ' + $i + ' payload ABCDEFGHIJKLMNOPQRSTUVWXYZ 0123456789 abcdefghijklmnopqrstuvwxyz')
}
[System.IO.File]::WriteAllText((Join-Path $dir 'sample.log'), $sb.ToString(), $enc)
Write-Output ('  generated 30000 lines, ' + (Get-Item (Join-Path $dir 'sample.log')).Length + ' bytes, job=' + $job)

$cfg = Get-Content (Join-Path $root 'logshipper.ini')
$cfg = $cfg | ForEach-Object {
  if ($_ -match '^job=')                    { 'job=' + $job }
  elseif ($_ -match '^instance=')           { 'instance=cpucheck-1' }
  elseif ($_ -match '^paths=')              { 'paths=E:\Git\logshipper\test\cpu_logs\*.log' }
  elseif ($_ -match '^positions_file=')     { 'positions_file=test/cpu_pos.json' }
  elseif ($_ -match '^batch_max_delay_ms=') { 'batch_max_delay_ms=200' }
  elseif ($_ -match '^log_file=')           { '; log_file disabled' }
  elseif ($_ -match '^log_file_level=')     { '; log_file_level disabled' }
  else                                      { $_ }
}
$cpuIni = Join-Path $root 'test\cpu.ini'
[System.IO.File]::WriteAllLines($cpuIni, $cfg, $enc)
Remove-Item (Join-Path $root 'test\cpu_pos.json') -Force -ErrorAction SilentlyContinue

Measure-Run 'B backfill (isolated)' $cpuIni 12

$ErrorActionPreference = 'Continue'
# Repo root = parent of the directory this script lives in (test/).
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$exe  = Join-Path $root 'logshipper.exe'
$ini  = Join-Path $root 'logshipper.ini'
$out  = Join-Path $root 'test\win_diag_out.txt'
$err  = Join-Path $root 'test\win_diag_err.txt'

Write-Output '=== stop existing logshipper processes (avoid two readers on same positions) ==='
Get-Process -Name logshipper -ErrorAction SilentlyContinue | ForEach-Object {
  Write-Output ("  stopping PID " + $_.Id)
  Stop-Process -Id $_.Id -Force
}
Start-Sleep -Milliseconds 700

Write-Output '=== force FULL rebuild with Windows FPC (-B) ==='
Set-Location $root
# Use fpc from PATH (set the full path here if your FPC isn't on PATH).
& 'fpc.exe' -B -Mobjfpc -Sh -O2 -Fu. logshipper.lpr 2>&1 |
  Select-String -Pattern 'Error|Fatal|Warning|lines compiled' | ForEach-Object { Write-Output ('  ' + $_.Line) }
Write-Output ('  exe exists: ' + (Test-Path $exe) + '  time: ' + (Get-Item $exe -ErrorAction SilentlyContinue).LastWriteTime)

Write-Output '=== run YOUR logshipper.ini, cwd=<repo root>, 8 seconds ==='
Remove-Item $out,$err -Force -ErrorAction SilentlyContinue
$p = Start-Process -FilePath $exe -ArgumentList @($ini) -WorkingDirectory $root -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -NoNewWindow
Write-Output ('  started PID ' + $p.Id)
Start-Sleep -Seconds 8
$exited = $p.HasExited
if (-not $exited) { Stop-Process -Id $p.Id -Force }
Write-Output ('  exited on its own: ' + $exited)
Start-Sleep -Milliseconds 300

Write-Output '=== STDERR / console log (first 30 lines) ==='
if (Test-Path $err) { Get-Content $err -TotalCount 30 } else { Write-Output '  (no stderr file!)' }
Write-Output '=== STDOUT (first 10) ==='
if (Test-Path $out) { Get-Content $out -TotalCount 10 }
Write-Output '=== counts ==='
if (Test-Path $err) {
  $t = Get-Content $err -Raw
  Write-Output ('  pushed batches : ' + ([regex]::Matches($t,'pushed \d+ lines')).Count)
  Write-Output ('  dropping       : ' + ([regex]::Matches($t,'dropping batch')).Count)
  Write-Output ('  WARN lines     : ' + ([regex]::Matches($t,'\[WARN\]')).Count)
  Write-Output ('  ERROR lines    : ' + ([regex]::Matches($t,'\[ERROR\]')).Count)
  Write-Output ('  total lines    : ' + (($t -split "`n").Count))
}
Write-Output '=== positions.json / logshipper.log ==='
Get-Item (Join-Path $root 'positions.json'),(Join-Path $root 'logshipper.log') -ErrorAction SilentlyContinue |
  Select-Object Name,Length,LastWriteTime | Format-Table -AutoSize
if (Test-Path (Join-Path $root 'positions.json')) {
  Write-Output '  positions content:'
  Get-Content (Join-Path $root 'positions.json') -TotalCount 5
}

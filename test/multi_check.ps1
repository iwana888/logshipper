$ErrorActionPreference = 'Continue'
$root = 'E:\Git\logshipper'
$dir  = Join-Path $root 'test\multi'
$enc  = New-Object System.Text.UTF8Encoding($false)
Set-Location $root
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$t = [DateTimeOffset]::UtcNow.AddMinutes(-2)
$stamp = $t.ToString('yyyyMMdd HHmmss') + '00'
$tag = $t.ToString('HHmmss')
$procs = @()

foreach ($n in 1,2) {
  $logFile = Join-Path $dir ('inst' + $n + '.log')
  $iniFile = Join-Path $dir ('inst' + $n + '.ini')
  $posRel  = 'test/multi/positions' + $n + '.json'
  $posFile = Join-Path $root $posRel
  Remove-Item $posFile -Force -ErrorAction SilentlyContinue
  [System.IO.File]::WriteAllLines($logFile, @(
    ($stamp + '  "4 info  [multi] instance ' + $n + ' line A'),
    ($stamp + '  ! info  [multi] instance ' + $n + ' line B')
  ), $enc)

  $job = 'multi_' + $tag + '_' + $n
  $cfg = Get-Content (Join-Path $root 'logshipper.ini')
  $cfg = $cfg | ForEach-Object {
    if ($_ -match '^job=')                    { 'job=' + $job }
    elseif ($_ -match '^instance=')           { 'instance=inst' + $n }
    elseif ($_ -match '^paths=')              { 'paths=' + $logFile }
    elseif ($_ -match '^positions_file=')     { 'positions_file=' + $posRel }
    elseif ($_ -match '^batch_max_delay_ms=') { 'batch_max_delay_ms=300' }
    elseif ($_ -match '^log_file=')           { '; log_file disabled for multi check' }
    elseif ($_ -match '^log_file_level=')     { '; disabled' }
    else                                      { $_ }
  }
  [System.IO.File]::WriteAllLines($iniFile, $cfg, $enc)

  $out = Join-Path $dir ('out' + $n + '.txt')
  $err = Join-Path $dir ('err' + $n + '.txt')
  Remove-Item $out,$err -Force -ErrorAction SilentlyContinue
  $p = Start-Process -FilePath (Join-Path $root 'logshipper.exe') -ArgumentList @($iniFile) `
    -WorkingDirectory $root -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -NoNewWindow
  $procs += [pscustomobject]@{ N=$n; Pid=$p.Id; Err=$err; Pos=$posFile; Job=$job }
  Write-Output ('started PID ' + $p.Id + ' with ' + $iniFile + ' -> job=' + $job + ' instance=inst' + $n)
}

Start-Sleep -Seconds 6
$end   = [DateTimeOffset]::UtcNow.AddMinutes(2).ToUnixTimeMilliseconds() * 1000000
$start = [DateTimeOffset]::UtcNow.AddMinutes(-10).ToUnixTimeMilliseconds() * 1000000
foreach ($x in $procs) {
  $txt = Get-Content $x.Err -Raw -ErrorAction SilentlyContinue
  Write-Output ('--- inst' + $x.N + ' ---')
  Write-Output ('  pushed batches = ' + ([regex]::Matches($txt,'pushed \d+ lines')).Count)
  Write-Output ('  WARN/ERROR = ' + ([regex]::Matches($txt,'\[WARN\]')).Count + '/' + ([regex]::Matches($txt,'\[ERROR\]')).Count)
  Write-Output ('  positions = ' + (Get-Content $x.Pos -Raw -ErrorAction SilentlyContinue))
  Stop-Process -Id $x.Pid -Force -ErrorAction SilentlyContinue
  $q = '{job="' + $x.Job + '"}'
  $uri = 'http://localhost:3100/loki/api/v1/query_range?query=' +
         [uri]::EscapeDataString($q) + "&start=$start&end=$end&limit=10"
  try {
    $r = Invoke-RestMethod -Uri $uri -TimeoutSec 10
    foreach ($s in $r.data.result) {
      Write-Output ('  loki stream: instance=' + $s.stream.instance + ' level=' + $s.stream.level + ' entries=' + $s.values.Count)
    }
  } catch { Write-Output ('  query failed: ' + $_.Exception.Message) }
}
Write-Output ('remaining logshipper processes = ' + ((Get-Process -Name logshipper -ErrorAction SilentlyContinue | Measure-Object).Count))

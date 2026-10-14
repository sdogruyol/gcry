# Runs one crash child of process_spec/regression/70_crash_report_exits_spec.cr
# -Runs times, each bounded at -Limit seconds; on a hang, two cdb stack
# snapshots of every thread, then kill. Tallies exit codes and the first line
# of output into $Out\summary.txt.
param(
  [string]$Exe,
  [string]$Example,
  [string]$EnvName,
  [int]$Runs = 10,
  [int]$Limit = 30,
  [string]$Out = "crash-out"
)
$ErrorActionPreference = "Continue"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$Exe = (Resolve-Path $Exe).Path
$bin = Split-Path $Exe
$dbgArch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }
$cdb = "C:\Program Files (x86)\Windows Kits\10\Debuggers\$dbgArch\cdb.exe"
if (-not (Test-Path $cdb)) { $cdb = $null }
$sym = "$bin;srv*C:\symcache*https://msdl.microsoft.com/download/symbols"
$tally = @{}
$hangs = 0
for ($i = 1; $i -le $Runs; $i++) {
  $so = "$Out\run.out"; $se = "$Out\run.err"
  Set-Item -Path "Env:$EnvName" -Value "1"
  $p = Start-Process -FilePath $Exe -ArgumentList "-e", "`"$Example`"" -NoNewWindow -PassThru -RedirectStandardOutput $so -RedirectStandardError $se
  Remove-Item -Path "Env:$EnvName"
  $null = $p.Handle
  if ($p.WaitForExit($Limit * 1000)) {
    $first = (((Get-Content $se -TotalCount 1) + "") -replace "0x[0-9a-fA-F]{5,}", "ADDR")
    $gcry = if (Select-String -Path $se -Pattern "^gcry: " -Quiet) { " +gcry-line" } else { "" }
    $key = "exit=$($p.ExitCode) $first$gcry"
    $tally[$key] = 1 + [int]$tally[$key]
    if ($i -eq 1) { Copy-Item $se "$Out\first-run.err" }
    continue
  }
  $hangs++
  $dir = "$Out\hang$hangs"
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  Copy-Item $so "$dir\stdout.txt"; Copy-Item $se "$dir\stderr.txt"
  $c1 = $p.TotalProcessorTime; Start-Sleep -Seconds 3; $p.Refresh(); $c2 = $p.TotalProcessorTime
  "HANG run=$i cpu $c1 -> $c2 (3 s)" | Tee-Object -FilePath "$Out\summary.txt" -Append
  if ($cdb) {
    & $cdb -pv -p $p.Id -y $sym -lines -c ".reload; !runaway 7; ~*kn 60; qd" *> "$dir\cdb-a.txt"
    Start-Sleep -Seconds 3
    & $cdb -pv -p $p.Id -y $sym -lines -c ".reload; !runaway 7; ~*kn 60; qd" *> "$dir\cdb-b.txt"
  }
  Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 1
}
"$Example runs=$Runs hangs=$hangs" | Tee-Object -FilePath "$Out\summary.txt" -Append
$tally.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { "{0,6}  {1}" -f $_.Value, $_.Key } | Tee-Object -FilePath "$Out\summary.txt" -Append

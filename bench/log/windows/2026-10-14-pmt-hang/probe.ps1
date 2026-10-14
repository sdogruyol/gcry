# Runs `parallel_mark_termination` (parent, both arms, as `make
# parallel-mark-termination` does) in a loop for -Minutes, each run bounded at
# -Limit seconds — under the bench's own 120 s per-child kill, so a hung child
# is still alive when we look. On a hang every parallel_mark_termination.exe
# gets: CPU time twice 5 s apart, two cdb stack snapshots (`!runaway`, `~*kn`)
# 5 s apart, and a full minidump of the second. Outcomes of every run are
# tallied in summary.txt.
param(
  [int]$Minutes = 40,
  [int]$Limit = 90,
  [int]$MaxHangs = 3,
  [string]$Out = "probe-out",
  [string]$Mode = "parent"
)
$ErrorActionPreference = "Continue"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$bin = (Resolve-Path "bin").Path
$exe = Join-Path $bin "parallel_mark_termination.exe"
$dbgArch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }
$cdb = "C:\Program Files (x86)\Windows Kits\10\Debuggers\$dbgArch\cdb.exe"
if (-not (Test-Path $cdb)) {
  $found = Get-ChildItem "C:\Program Files (x86)\Windows Kits\10\Debuggers" -Recurse -Filter cdb.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  $cdb = if ($found) { $found.FullName } else { $null }
}
"cdb=$cdb arch=$env:PROCESSOR_ARCHITECTURE mode=$Mode limit=$Limit" | Tee-Object -FilePath "$Out\summary.txt" -Append
Get-ChildItem $bin | Format-Table Name, Length | Out-String | Tee-Object -FilePath "$Out\summary.txt" -Append
$sym = "$bin;srv*C:\symcache*https://msdl.microsoft.com/download/symbols"

$deadline = (Get-Date).AddMinutes($Minutes)
$runs = 0; $hangs = 0
$tally = @{}
while ((Get-Date) -lt $deadline -and $hangs -lt $MaxHangs) {
  $runs++
  $so = "$Out\run.out"; $se = "$Out\run.err"
  if ($Mode -eq "child") {
    $env:GCRY_MARK_BUSY_UNLOCKED = "1"
    $p = Start-Process -FilePath $exe -ArgumentList "--child", "--unlocked" -NoNewWindow -PassThru -RedirectStandardOutput $so -RedirectStandardError $se
    Remove-Item Env:GCRY_MARK_BUSY_UNLOCKED
  } else {
    $p = Start-Process -FilePath $exe -NoNewWindow -PassThru -RedirectStandardOutput $so -RedirectStandardError $se
  }
  $null = $p.Handle
  if ($p.WaitForExit($Limit * 1000)) {
    $text = (Get-Content $so -Raw) + (Get-Content $se -Raw)
    if ($Mode -eq "child") {
      $first = ((Get-Content $se -TotalCount 1) -replace "0x[0-9a-fA-F]+", "ADDR")
      $key = "exit=$($p.ExitCode) $first"
    } else {
      $line = ($text -split "`n" | Where-Object { $_ -like "unlocked:*" } | Select-Object -First 1)
      $line = ($line -replace "stolen=\d+", "stolen=N" -replace "runs=\d+", "runs=N" -replace "damage=.*", "damage=...").Trim()
      $key = "exit=$($p.ExitCode) $line"
    }
    $tally[$key] = 1 + [int]$tally[$key]
    continue
  }
  $hangs++
  $dir = "$Out\hang$hangs"
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  "HANG run=$runs at $(Get-Date -Format o)" | Tee-Object -FilePath "$Out\summary.txt" -Append
  Copy-Item $so "$dir\stdout.txt"; Copy-Item $se "$dir\stderr.txt"
  $procs = Get-CimInstance Win32_Process -Filter "Name='parallel_mark_termination.exe'"
  $procs | Select-Object ProcessId, ParentProcessId, CommandLine | Format-List | Out-File "$dir\procs.txt"
  foreach ($pr in $procs) {
    $id = $pr.ProcessId
    $c1 = (Get-Process -Id $id -ErrorAction SilentlyContinue).TotalProcessorTime
    Start-Sleep -Seconds 5
    $c2 = (Get-Process -Id $id -ErrorAction SilentlyContinue).TotalProcessorTime
    "pid=$id ppid=$($pr.ParentProcessId) cmd=$($pr.CommandLine) cpu: $c1 -> $c2 (5 s)" | Tee-Object -FilePath "$Out\summary.txt" -Append
    if ($cdb) {
      & $cdb -pv -p $id -y $sym -lines -c ".reload; !runaway 7; ~*kn 80; qd" *> "$dir\cdb-$id-a.txt"
      Start-Sleep -Seconds 5
      & $cdb -p $id -y $sym -lines -c ".reload; !runaway 7; ~*kn 80; .dump /ma $dir\pmt-$id.dmp; qd" *> "$dir\cdb-$id-b.txt"
    }
  }
  foreach ($pr in $procs) { Stop-Process -Id $pr.ProcessId -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Seconds 1
}
"runs=$runs hangs=$hangs" | Tee-Object -FilePath "$Out\summary.txt" -Append
$tally.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { "{0,6}  {1}" -f $_.Value, $_.Key } | Tee-Object -FilePath "$Out\summary.txt" -Append

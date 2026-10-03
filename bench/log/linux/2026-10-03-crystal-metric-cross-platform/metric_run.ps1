param([int]$Trials = 5)
$ErrorActionPreference = 'Continue'
$benches = 'Binarytrees','Brainfuck','Brainfuck2','Knuckeotide','RegexDna','Revcomp','Threadring','Matmul','JsonGenerate','JsonParseSerializable','JsonParsePull','Primes','JsonParsePure'
$rows = @()
foreach ($t in 1..$Trials) {
  foreach ($b in $benches) {
    $arms = @('boehm', 'gcry'); if ($t % 2 -eq 0) { $arms = @('gcry', 'boehm') }
    foreach ($arm in $arms) {
      $o = Join-Path $env:RUNNER_TEMP "m.txt"
      $p = Start-Process -FilePath "bin/cm-$arm.exe" -ArgumentList $b -NoNewWindow -PassThru -RedirectStandardOutput $o -RedirectStandardError "$o.err"
      $peak = 0
      while (-not $p.HasExited) { try { $p.Refresh(); if ($p.PeakWorkingSet64 -gt $peak) { $peak = $p.PeakWorkingSet64 } } catch {}; Start-Sleep -Milliseconds 20 }
      try { if ($p.PeakWorkingSet64 -gt $peak) { $peak = $p.PeakWorkingSet64 } } catch {}
      $line = (Get-Content $o | Select-String -Pattern "^${b}:" | Select-Object -Last 1)
      $secs = if ($line -and ($line.Line -match ' in ([0-9.]+)s')) { [double]$Matches[1] } else { -1 }
      Write-Host "ROW $t $b $arm $secs $([int]($peak / 1024)) rc=$($p.ExitCode)"
    }
  }
}

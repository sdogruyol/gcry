#Requires -Version 7
param(
    [string] $Variant = 'headers',
    [int] $Runs = 200,
    [string[]] $Specs = @('79_alloc_entry_frame_uninitialized', '86_alloc_slow_path_clean_frames'),
    [string[]] $Builds = @('release'),
    [string[]] $Modes = @('settle')
)
$ErrorActionPreference = 'Stop'
$crystal = if ($env:GCRY_CI_CRYSTAL) { $env:GCRY_CI_CRYSTAL } else { 'crystal' }
$env:GCRY_BITMAP_ALLOC = if ($Variant -eq 'freelist') { '0' } else { '1' }
$flags = if ($Variant -eq 'default') { @() } else { @('-Dgcry_block_headers') }
New-Item -ItemType Directory -Force bin | Out-Null
$total = 0
foreach ($build in $Builds) {
    foreach ($spec in $Specs) {
        $binary = Join-Path $PWD "bin/p_$($spec.Substring(0, 2))_$build.exe"
        $bflags = if ($build -eq 'release') { @('--release') } else { @() }
        & $crystal (@('build') + $bflags + @('-Dgc_none') + $flags + @("process_spec/regression/$($spec)_spec.cr", '-o', $binary, '--error-trace'))
        if ($LASTEXITCODE -ne 0) { throw "build $spec failed" }
      foreach ($mode in $Modes) {
        $env:GCRY_PROBE_NOSETTLE = if ($mode -eq 'nosettle') { '1' } else { '0' }
        $fails = 0
        $diag = @{}
        for ($i = 1; $i -le $Runs; $i++) {
            $out = & $binary 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) {
                $fails++
                Write-Host "=== $spec $build run $i FAILED"
                Write-Host $out
            }
            foreach ($l in ($out -split "`n")) {
                if ($l -match '^diag\d+: (\S+ collector=\S*)') { $diag[$Matches[1]] = 1 + [int]$diag[$Matches[1]] }
            }
            if ($i -le 3) { ($out -split "`n") | Where-Object { $_ -match '^(diag|stale)' } | ForEach-Object { Write-Host "$spec run ${i}: $_" } }
        }
        Write-Host "RESULT $spec $build $Variant $mode fails=$fails of $Runs diag=$(($diag.GetEnumerator() | ForEach-Object { "$($_.Key):$($_.Value)" }) -join ',')"
        if ($mode -eq 'settle') { $total += $fails }
      }
    }
}
if ($total -ne 0) { exit 1 }

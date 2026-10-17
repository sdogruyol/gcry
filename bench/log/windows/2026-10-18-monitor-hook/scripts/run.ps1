# PROBE ONLY. Every arm runs whatever the one before it did.
$ErrorActionPreference = 'Continue'
$crystal = if ($env:GCRY_CI_CRYSTAL) { $env:GCRY_CI_CRYSTAL } else { 'crystal' }
New-Item -ItemType Directory -Force bin | Out-Null

function Build-Run {
    param([string] $Label, [string] $Source, [string] $Exe, [string[]] $RunArgs)
    Write-Host "=== $Label ==="
    & $crystal build -Dgc_none $Source -o $Exe --error-trace
    if ($LASTEXITCODE -ne 0) { Write-Host "=== ${Label}: BUILD FAILED $LASTEXITCODE"; return }
    & $Exe @RunArgs
    Write-Host "=== ${Label}: exit=$LASTEXITCODE"
}

$s76 = 'process_spec/regression/76_monitor_deep_frame_root_spec.cr'
$s77 = 'process_spec/regression/77_library_collect_monitor_gate_spec.cr'
Build-Run 'probe fixed' 'bench/monitor_probe.cr' 'bin/monitor_probe.exe' @()
Build-Run 'spec76 alone fixed' $s76 'bin/spec76.exe' @('-v')
Build-Run 'spec77 alone fixed' $s77 'bin/spec77.exe' @('-v')
git apply probe/revert-fix.patch
Build-Run 'probe scan-nofix' 'bench/monitor_probe.cr' 'bin/monitor_probe_nofix.exe' @()
Build-Run 'spec76 alone scan-nofix' $s76 'bin/spec76_nofix.exe' @('-v')
git apply -R probe/revert-fix.patch
git apply probe/revert-gate.patch
Build-Run 'spec77 alone gate-nofix' $s77 'bin/spec77_nofix.exe' @('-v')
git apply -R probe/revert-gate.patch
git status --short
exit 0

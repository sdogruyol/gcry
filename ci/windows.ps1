# PowerShell 7 (`pwsh`): `[IO.Path]::GetRelativePath` and `utf8NoBOM` below do
# not exist in Windows PowerShell 5.1, which failed half-way through the first
# spec step instead of saying so.
#Requires -Version 7

param(
    [ValidateSet('default', 'headers', 'freelist')]
    [string] $Variant = 'default',
    [ValidateSet('all', 'specs', 'samples')]
    [string] $Suite = 'all',
    [ValidateSet('x86_64', 'aarch64')]
    [string] $Architecture = 'x86_64'
)

$ErrorActionPreference = 'Stop'

function Invoke-Checked {
    param([string] $Command, [string[]] $Arguments)
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Command $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
}

# `crystal spec` compiles to `<cache>/crystal-run-spec.tmp.exe`, runs it, and
# deletes it, and on these runners the delete races a handle on the image that
# outlives the process: two of four master runs on 2026-09-10, and again on
# 2026-09-23 (run 35846099330, windows arm64 freelist) *after* the per-label
# cache directory made that path private to one invocation — so the race is the
# lingering lock, not the sharing. Each time the specs had already reported
# `0 failures` and the step failed as "you've found a bug in the Crystal
# compiler". So the specs are built under a name of their own and run, which is
# what `crystal spec` does minus the delete: an entry file that `require`s each
# `<Dir>/**/*_spec.cr`, the same compile flags, the runner options passed to the
# binary.
#
# The entry file is not a style choice. Handing the spec files to `crystal
# build` as main sources makes a `{% skip_file %}` in one of them skip every
# main source *after* it too, and `spec/segv_report_spec.cr` opens with
# `skip_file unless flag?(:unix)`: the first version of this lost the 57
# examples that sort after it (281 → 224 on x86_64 default, run 35849478402)
# and stayed green. Through `require` only that one file is skipped.
function Invoke-CrystalSpec {
    param([string] $Label, [string] $Dir, [string[]] $Flags)
    $previous = $env:CRYSTAL_CACHE_DIR
    $root = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
    $env:CRYSTAL_CACHE_DIR = Join-Path $root "gcry-cache-$Architecture-$Variant-$Label"
    try {
        $Flags = @($Flags | Where-Object { $_ })
        $bin = Join-Path $PWD 'bin'
        New-Item -ItemType Directory -Force $bin | Out-Null
        $requires = @(Get-ChildItem -Path $Dir -Recurse -Filter '*_spec.cr' | Sort-Object FullName | ForEach-Object {
            'require "' + ([IO.Path]::GetRelativePath($bin, $_.FullName) -replace '\\', '/') + '"'
        })
        if ($requires.Count -eq 0) { throw "no *_spec.cr under $Dir" }
        $entry = Join-Path $bin "spec_$Architecture-$Variant-$Label.cr"
        Set-Content -Path $entry -Value $requires -Encoding utf8NoBOM
        $binary = Join-Path $bin "spec_$Architecture-$Variant-$Label.exe"
        Invoke-Checked $crystal (@('build') + $Flags + @($entry, '-o', $binary, '--error-trace'))
        Invoke-Checked $binary @('--fail-fast')
    }
    finally {
        $env:CRYSTAL_CACHE_DIR = $previous
    }
}

function Assert-NativeBinary {
    param([string] $Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $pe = [BitConverter]::ToInt32($bytes, 0x3c)
    $expected = if ($Architecture -eq 'aarch64') { 0xAA64 } else { 0x8664 }
    if ([BitConverter]::ToUInt16($bytes, $pe + 4) -ne $expected) {
        throw "$Path is not a native $Architecture executable"
    }
}

$crystal = if ($env:GCRY_CI_CRYSTAL) { $env:GCRY_CI_CRYSTAL } else { 'crystal' }
$version = & $crystal --version
if ($LASTEXITCODE -ne 0) { throw 'Crystal version check failed' }
$version | Write-Host
if (($version -join "`n") -notmatch "Default target: $Architecture.*windows") {
    throw "Expected a Windows $Architecture compiler target"
}

$previousBitmap = $env:GCRY_BITMAP_ALLOC
Push-Location (Join-Path $PSScriptRoot '..')
try {
    # default: the headerless layout (the compile default). headers: the
    # 16-byte header layout on the bitmap allocator. freelist: the header
    # layout on the freelist — GCRY_BITMAP_ALLOC=0 is only read there.
    $env:GCRY_BITMAP_ALLOC = if ($Variant -eq 'freelist') { '0' } else { '1' }
    $flags = if ($Variant -eq 'default') { @() } else { @('-Dgcry_block_headers') }

    if ($Suite -ne 'samples') {
        Write-Host "Windows library specs ($Variant)"
        Invoke-CrystalSpec 'spec' 'spec' $flags
        Write-Host "Windows process GC specs ($Variant)"
        Invoke-CrystalSpec 'process' 'process_spec' (@('-Dgc_none') + $flags)
        if ($Variant -eq 'default') {
            Write-Host "Windows thread-local storage roots"
            New-Item -ItemType Directory -Force bin | Out-Null
            $tls = Join-Path $PWD 'bin/tls_roots_windows.exe'
            Invoke-Checked $crystal (@('build', '-Dgc_none', 'bench/tls_roots.cr', '-o', $tls, '--error-trace'))
            Invoke-Checked $tls @()
            $env:GCRY_TLS_ROOTS = '0'
            & $tls
            if ($LASTEXITCODE -eq 0) {
                throw 'GCRY_TLS_ROOTS=0 kept a block that must die'
            }
            Remove-Item Env:GCRY_TLS_ROOTS
            Invoke-Checked $tls @('--control')
            Invoke-Checked $tls @('--collect-elsewhere')

            # The holders search compiled on this platform for the first time
            # in v0.26.1, and the only path that reaches it here is the arm
            # above coming out INCONCLUSIVE — which is a failure path. Run the
            # harness whose answer is known instead, so the walk is exercised
            # on Windows while it is green: every constructed holder must be
            # found and a block with none must report none.
            Write-Host "Windows holders search"
            $holders = Join-Path $PWD 'bin/holders_find_windows.exe'
            Invoke-Checked $crystal (@('build', '-Dgc_none', 'bench/holders_find.cr', '-o', $holders, '--error-trace'))
            Invoke-Checked $holders @()

            # This platform used to answer a full capture table by refusing the
            # whole stop -- `raise_thread_suspension_error` said "or exceeded 64
            # threads" -- so a process with 65 threads could not collect at all.
            # The table grows now; this is the gate that says every suspended
            # thread got a slot, with the pre-fix bound pinned back by
            # GCRY_STW_FIXED_SLOTS=1 as the arm that must fail.
            Write-Host "Windows STW capture coverage"
            $coverage = Join-Path $PWD 'bin/stw_capture_coverage_windows.exe'
            Invoke-Checked $crystal (@('build', '-Dgc_none', 'bench/stw_capture_coverage.cr', '-o', $coverage, '--error-trace'))
            Invoke-Checked $coverage @()

            # A starting thread is on the thread list before its main fiber
            # exists, and this platform bounded a thread's stack by that fiber:
            # stopped in between, the thread was not scanned and the new fiber
            # was swept, then published — `Fiber#running?` at C0000005 in the
            # tls-roots step above, 3 runs in 100. Pre-fix, 300 births lost a
            # fiber in 6 runs of 10 (9 in 3 000); 3 000 births, ~8 s here.
            # A pointer held only in a suspended thread's XMM / NEON register:
            # this platform reads them out of `GetThreadContext`, and turning
            # the register roots off must lose the block.
            Write-Host "Windows FP register roots"
            $fpr = Join-Path $PWD 'bin/fp_register_root_windows.exe'
            Invoke-Checked $crystal (@('build', '-Dgc_none', 'bench/fp_register_root.cr', '-o', $fpr, '--error-trace'))
            Invoke-Checked $fpr @()
            Invoke-Checked $fpr @('--control')
            $env:GCRY_DISABLE_GREG_ROOTS = '1'
            & $fpr
            if ($LASTEXITCODE -eq 0) {
                throw 'GCRY_DISABLE_GREG_ROOTS=1 kept a block held only in an FP register'
            }
            Remove-Item Env:GCRY_DISABLE_GREG_ROOTS

            # Nothing below a suspended thread's SP is live on this platform, and
            # the scan stops at the red zone. The red arm (the old 4 KiB) is
            # asserted on x86_64, where it kept the block 6 of 6; on arm64 the
            # freed half was 4 of 4 in CI and the red arm is only printed. An
            # x64 build under ARM64 emulation kept the block with the window
            # closed, from some other copy, which is not this job.
            Write-Host "Windows dead stack below SP"
            $dsb = Join-Path $PWD 'bin/dead_stack_below_sp_windows.exe'
            Invoke-Checked $crystal (@('build', '-Dgc_none', 'bench/dead_stack_below_sp.cr', '-o', $dsb, '--error-trace'))
            Invoke-Checked $dsb @('--control')
            Invoke-Checked $dsb @('--expect-freed')
            $env:GCRY_SUSPENDED_SP_SLACK = '4096'
            & $dsb --expect-freed
            $redRc = $LASTEXITCODE
            Remove-Item Env:GCRY_SUSPENDED_SP_SLACK
            if ($Architecture -eq 'x86_64' -and $redRc -eq 0) {
                throw 'GCRY_SUSPENDED_SP_SLACK=4096 freed a block the dead stack names'
            }

            Write-Host "Windows thread birth keeps its main fiber"
            $birth = Join-Path $PWD 'bin/thread_birth_fiber_windows.exe'
            Invoke-Checked $crystal (@('build', '-Dgc_none', 'bench/thread_birth_fiber.cr', '-o', $birth, '--error-trace'))
            Invoke-Checked $birth @('3000')

            # Spawn storm and rapid create/join under collection. Phase 3 is
            # a Unix signal and is skipped here.
            Write-Host "Windows thread storm"
            $storm = Join-Path $PWD 'bin/thread_storm_windows.exe'
            Invoke-Checked $crystal (@('build', '-Dgc_none', 'bench/thread_storm.cr', '-o', $storm, '--error-trace'))
            Invoke-Checked $storm @()

            # The post-STW flush walk against a mutator's unmap. The scheduled
            # control must fault; stress-control children that hang are only
            # noted, but each costs its 30 s deadline, so four attempts.
            Write-Host "Windows dormant flush race"
            $dfr = Join-Path $PWD 'bin/dormant_flush_race_windows.exe'
            Invoke-Checked $crystal (@('build', '-Dgc_none', 'bench/dormant_flush_race.cr', '-o', $dfr, '--error-trace'))
            $env:DORMANT_FLUSH_RACE_ATTEMPTS = '4'
            Invoke-Checked $dfr @()
            Remove-Item Env:DORMANT_FLUSH_RACE_ATTEMPTS

            # A mutator's large-cache trim against the allocator. The unlocked
            # control faulted (C0000005) in 5 of 5 on x64 and arm64.
            Write-Host "Windows large cache race"
            $lcr = Join-Path $PWD 'bin/large_cache_race_windows.exe'
            Invoke-Checked $crystal (@('build', '-Dgc_none', 'bench/large_cache_race.cr', '-o', $lcr, '--error-trace'))
            Invoke-Checked $lcr @()

            # The STW watchdog on SuspendThread: collector phases, the
            # pre-suspend step and `stopped-before-flush`.
            Write-Host "Windows STW watchdog"
            $wd = Join-Path $PWD 'bin/stw_watchdog_windows.exe'
            Invoke-Checked $crystal (@('build', '-Dgc_none', 'bench/stw_watchdog.cr', '-o', $wd, '--error-trace'))
            Invoke-Checked $wd @()

            # No mutator may read the chunk index unlocked during a stop; the
            # red arm clears `@world_stopped` after the resume (4 000+ reads).
            Write-Host "Windows STW chunk-index race"
            $sir = Join-Path $PWD 'bin/stw_index_race_windows.exe'
            Invoke-Checked $crystal (@('build', '-Dgc_none', 'bench/stw_index_race.cr', '-o', $sir, '--error-trace'))
            Invoke-Checked $sir @()
        }
    }

    if ($Suite -ne 'specs') {
        New-Item -ItemType Directory -Force bin | Out-Null
        $samples = @(
            @{ Name = 'hello'; Arguments = @() },
            @{ Name = 'stress'; Arguments = @('300') },
            @{ Name = 'json_churn'; Arguments = @('800') },
            @{ Name = 'stw_sp_clamp'; Arguments = @() }
        )
        if ($Variant -eq 'default') {
            $legacy = Join-Path $PWD 'bin/hello_windows_legacy.exe'
            Invoke-Checked $crystal @('build', '-Dgc_none', '-Dwithout_mt', 'samples/hello.cr', '-o', $legacy)
            Assert-NativeBinary $legacy
            Invoke-Checked $legacy @()
        }
        foreach ($sample in $samples) {
            $binary = Join-Path $PWD "bin/$($sample.Name)_windows_$Variant.exe"
            Write-Host "Windows release sample: $($sample.Name) ($Variant)"
            Invoke-Checked $crystal (@('build', '--release', '-Dgc_none') + $flags + @("samples/$($sample.Name).cr", '-o', $binary, '--error-trace'))
            Assert-NativeBinary $binary
            Invoke-Checked $binary $sample.Arguments
        }
    }
}
finally {
    $env:GCRY_BITMAP_ALLOC = $previousBitmap
    Pop-Location
}

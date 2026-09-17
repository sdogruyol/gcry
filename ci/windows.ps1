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
# deletes it. Two invocations in one job share that path, and on the ARM64
# runner the delete raced a lingering handle on the just-exited image often
# enough to fail two of four master runs on 2026-09-10 — after the specs
# themselves had reported `0 failures`, and reported as "you've found a bug in
# the Crystal compiler". One cache directory per invocation removes the shared
# path; the exit code is still checked, so a real failure fails. Named rather
# than randomised so a re-run reuses the same compile cache.
function Invoke-CrystalSpec {
    param([string] $Label, [string[]] $Arguments)
    $previous = $env:CRYSTAL_CACHE_DIR
    $root = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
    $env:CRYSTAL_CACHE_DIR = Join-Path $root "gcry-cache-$Architecture-$Variant-$Label"
    try {
        Invoke-Checked $crystal $Arguments
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
        Invoke-CrystalSpec 'spec' (@('spec') + $flags + @('--error-trace', '--fail-fast'))
        Write-Host "Windows process GC specs ($Variant)"
        Invoke-CrystalSpec 'process' (@('spec', '-Dgc_none') + $flags + @('process_spec', '--error-trace', '--fail-fast'))
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

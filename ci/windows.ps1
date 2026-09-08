param(
    [ValidateSet('default', 'freelist', 'headerless')]
    [string] $Variant = 'default',
    [ValidateSet('all', 'specs', 'samples')]
    [string] $Suite = 'all'
)

$ErrorActionPreference = 'Stop'

function Invoke-Checked {
    param([string] $Command, [string[]] $Arguments)
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Command $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
}

$previousBitmap = $env:GCRY_BITMAP_ALLOC
Push-Location (Join-Path $PSScriptRoot '..')
try {
    $env:GCRY_BITMAP_ALLOC = if ($Variant -eq 'freelist') { '0' } else { '1' }
    $flags = if ($Variant -eq 'headerless') { @('-Dgcry_headerless') } else { @() }

    if ($Suite -ne 'samples') {
        Write-Host "Windows library specs ($Variant)"
        Invoke-Checked crystal (@('spec') + $flags + @('--error-trace', '--fail-fast'))
        Write-Host "Windows process GC specs ($Variant)"
        Invoke-Checked crystal (@('spec', '-Dgc_none') + $flags + @('process_spec', '--error-trace', '--fail-fast'))
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
            Invoke-Checked crystal @('build', '-Dgc_none', '-Dwithout_mt', 'samples/hello.cr', '-o', $legacy)
            Invoke-Checked $legacy @()
        }
        foreach ($sample in $samples) {
            $binary = Join-Path $PWD "bin/$($sample.Name)_windows_$Variant.exe"
            Write-Host "Windows release sample: $($sample.Name) ($Variant)"
            Invoke-Checked crystal (@('build', '--release', '-Dgc_none') + $flags + @("samples/$($sample.Name).cr", '-o', $binary, '--error-trace'))
            Invoke-Checked $binary $sample.Arguments
        }
    }
}
finally {
    $env:GCRY_BITMAP_ALLOC = $previousBitmap
    Pop-Location
}

param([Parameter(Mandatory)][string] $Msys2Location)
$ErrorActionPreference = 'Stop'

$archive = Join-Path $env:RUNNER_TEMP 'crystal-1.21.0-windows-aarch64.zip'
$destination = Join-Path $env:RUNNER_TEMP 'crystal-windows-aarch64'
$url = 'https://github.com/crystal-lang/crystal/releases/download/1.21.0/crystal-1.21.0-windows-aarch64-gnu-unsupported.zip'
Invoke-WebRequest -Uri $url -OutFile $archive
$expected = 'f5d11da3b1727ef49e4acffabcebab6229a631886f6164a94475be1f1390ae83'
if ((Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) {
    throw 'Crystal ARM64 archive checksum mismatch'
}
Expand-Archive -LiteralPath $archive -DestinationPath $destination -Force
$crystalBin = Join-Path $destination 'bin'
$clangRoot = Join-Path $Msys2Location 'clangarm64'
$clangBin = Join-Path $clangRoot 'bin'
$compiler = Join-Path $crystalBin 'crystal.exe'
$bytes = [IO.File]::ReadAllBytes($compiler)
$pe = [BitConverter]::ToInt32($bytes, 0x3c)
if ([BitConverter]::ToUInt16($bytes, $pe + 4) -ne 0xAA64) {
    throw 'Expected a native ARM64 Crystal compiler'
}
if (!(Test-Path (Join-Path $clangBin 'clang.exe'))) { throw 'ARM64 clang is missing' }
@($crystalBin, $clangBin) | Add-Content $env:GITHUB_PATH
@(
    "GCRY_CI_CRYSTAL=$compiler",
    "CC=$(Join-Path $clangBin 'clang.exe')",
    "CRYSTAL_PATH=lib;$(Join-Path $destination 'share/crystal/src')",
    "CRYSTAL_LIBRARY_PATH=$(Join-Path $clangRoot 'lib')"
) | Add-Content $env:GITHUB_ENV

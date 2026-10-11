#!/usr/bin/env bash
# The ARM64 Windows jobs' linker, C compiler and runtime libraries, from MSYS2
# CLANGARM64, at fixed versions.
#
# The jobs used to take whatever `pacman -S mingw-w64-clang-aarch64-crystal
# mingw-w64-clang-aarch64-lld` resolved to. On 2026-10-10 that moved clang,
# lld, libc++, libunwind, compiler-rt and llvm-libs from 22.1.8 to 23.1.3 (and
# the crystal package from 1.21.1-1 to 1.21.1-2). The pinned Crystal 1.21.0
# compiler (ci/install-windows-arm64.ps1) then crashed building a spec with
# "Missing hash key for value: 104 (KeyError)" in every arm64 job, master's
# included (run 38034037360), with no gcry change between a green and a red
# run. These are the packages the last green run installed (run 37975282285).
#
# A newer toolchain is taken by editing this list, in a commit CI can turn red.
set -euo pipefail

repo=https://repo.msys2.org/mingw/clangarm64
pkgs=(
  bzip2-1.0.8-4
  clang-22.1.8-3
  clang-libs-22.1.8-3
  compiler-rt-22.1.8-3
  crt-14.0.0.r426.g4564ee4b5-1
  crystal-1.21.1-1
  gc-8.2.12-1
  gmp-6.3.0-2
  headers-14.0.0.r426.g4564ee4b5-1
  libatomic_ops-7.10.0-1
  libc++-22.1.8-1
  libffi-3.8.0-1
  libiconv-1.19-1
  libunwind-22.1.8-1
  libwinpthread-14.0.0.r426.g4564ee4b5-1
  libxml2-2.15.4-1
  libyaml-0.2.5-2
  lld-22.1.8-3
  llvm-libs-22.1.8-3
  llvm-tools-22.1.8-3
  openssl-3.6.5-1
  pcre2-10.49-1
  wineditline-2.208-1
  winpthreads-14.0.0.r426.g4564ee4b5-1
  zlib-1.3.2-2
  zstd-1.5.7-2
)
urls=()
for p in "${pkgs[@]}"; do
  urls+=("$repo/mingw-w64-clang-aarch64-$p-any.pkg.tar.zst")
done

# Mirrors occasionally exceed pacman's short transfer timeout. Completed
# downloads are reused; a final failure still fails CI.
for attempt in 1 2 3; do
  if pacman --noconfirm -U --needed "${urls[@]}"; then
    clang --version
    exit 0
  fi
  sleep "$((attempt * 5))"
done
exit 1

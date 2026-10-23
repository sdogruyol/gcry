#!/usr/bin/env bash
# Image 0 versus the executable, on the runner: plain, under
# DYLD_INSERT_LIBRARIES, with the dylib linked, and both. Each arm prints the
# dylib constructor's view (if loaded), the view at Crystal main, and the
# verdict of bench/darwin_image0.cr. Exits non-zero if any arm failed.
set -u
D=bench/log/macos/2026-10-23-darwin-image0
mkdir -p bin
sw_vers || true
uname -m
cc -dynamiclib -o bin/libinject.dylib "$D/inject.c" -install_name @rpath/libinject.dylib || exit 2
crystal build -Dgc_none bench/darwin_image0.cr -o bin/darwin_image0 || exit 2
crystal build -Dgc_none bench/darwin_image0.cr -o bin/darwin_image0_linked \
  --link-flags "-L$PWD/bin -linject -Wl,-rpath,$PWD/bin" || exit 2
otool -L bin/darwin_image0_linked | grep inject

rc=0
arm() {
  echo "== $1"
  shift
  "$@"
  local r=$?
  echo "exit=$r"
  [ $r -eq 0 ] || rc=1
}
arm plain bin/darwin_image0
arm insert env DYLD_INSERT_LIBRARIES="$PWD/bin/libinject.dylib" bin/darwin_image0
arm linked bin/darwin_image0_linked
arm linked+insert env DYLD_INSERT_LIBRARIES="$PWD/bin/libinject.dylib" bin/darwin_image0_linked
cp bin/libinject.dylib bin/libinject2.dylib
install_name_tool -id @rpath/libinject2.dylib bin/libinject2.dylib
arm insert-two env DYLD_INSERT_LIBRARIES="$PWD/bin/libinject.dylib:$PWD/bin/libinject2.dylib" bin/darwin_image0
exit $rc

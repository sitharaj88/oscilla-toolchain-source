#!/bin/bash
# ---------------------------------------------------------------------------
# On-device smoke gate. Run from Windows Git Bash (adb must be on PATH), after
# 05-assemble.sh has installed the payload into the Gradle module.
#
# Pushes the real shipped payload to the phone in the exact production shape —
# flat lib*.so directory + symlink farm — and builds Blink.ino with it. The hex
# must md5 to the reference.
#
# This is NOT a test of Android's exec rules. The spike settled those
# (docs/ARDUINO_COMPILER.md §5.2), and §5.1 is explicit that adb shell is the
# wrong tool for that question. What this checks is narrower and still worth a
# lot: that the bionic aarch64 binaries we just built actually run on real
# hardware and produce correct output. The app-context exec path is covered by
# the instrumented test in :arduino:toolchain.
# ---------------------------------------------------------------------------
set -euo pipefail

# Git Bash / MSYS2 rewrites any argument that looks like an absolute POSIX path
# into a Windows path before exec'ing a native binary — and adb.exe is native.
# So `adb shell mkdir -p /data/local/tmp/oscilla-avr` arrives on the phone as
#     mkdir -p 'C:/Program Files/Git/data/local/tmp/oscilla-avr'
#     mkdir: 'C:': Read-only file system
#
# Every path this script hands to adb is a DEVICE path, so switch conversion off
# for all of them. A prefix list ('/data') is not enough: the rule matches only
# arguments that START with the prefix, and the exec probes below pass
# `LD_LIBRARY_PATH=/data/...`, which is mangled just the same. The one argument
# that genuinely is a host path — the `adb push` source — is handled by pushing
# relative names from inside the staging directory instead.
export MSYS2_ARG_CONV_EXCL='*'

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
MOD="$REPO/arduino/toolchain/src/main"
GV=7.3.0
REF_MD5=e52c115ebdc2de4a3b0d2668011e1dce

DEV=/data/local/tmp/oscilla-avr
NLD="$DEV/nativeLibraryDir"     # stands in for the app's read-only lib dir
# Stands in for filesDir/avr-toolchain/<gen>. The directory MUST be named `avr`
# directly under $OC_ROOT: build-blink.sh derives the toolchain prefix as
# "$OC_ROOT/avr" and puts "$OC_ROOT/avr/bin" on PATH. It also treats an existing
# "$OC_ROOT/lib" as the spike's bundled-glibc directory and overwrites
# LD_LIBRARY_PATH with it — hence OC_ROOT=$DEV (which has no lib/) rather than
# $TC (whose lib/ is lib/gcc/avr/<ver>, and would break the loader path).
TC="$DEV/avr"

[ -d "$MOD/jniLibs/arm64-v8a" ] || { echo "no payload — run 05-assemble.sh first"; exit 1; }
adb get-state >/dev/null || { echo "no device"; exit 1; }

echo "=== [1/5] staging locally ==="
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
# `avr`, not `tc`: the directory name has to match $TC's basename, because
# build-blink.sh derives the prefix as "$OC_ROOT/avr" (see the $TC note above).
mkdir -p "$STAGE/nativeLibraryDir" "$STAGE/avr"
cp "$MOD/jniLibs/arm64-v8a"/*.so "$STAGE/nativeLibraryDir/"
unzip -q "$MOD/assets/toolchain-data.zip" -d "$STAGE/avr"
cp "$REPO/tools/avr-spike/Blink.ino" "$STAGE/Blink.ino"
cp "$REPO/tools/avr-spike/build-blink.sh" "$STAGE/build-blink.sh"
echo "    $(find "$STAGE" -type f | wc -l) files, $(du -sh "$STAGE" | cut -f1)"

echo "=== [2/5] pushing ==="
adb shell rm -rf "$DEV"
adb shell mkdir -p "$DEV"
# `adb push <dir>/. <dest>` — the Unix idiom for "copy the CONTENTS" — does not
# survive Git Bash. MSYS rewrites the source into a Windows path, adb resolves
# its basename to the directory itself, and everything lands one level too deep
# in $DEV/tmp.XXXXXXXX/. Naming the top-level entries is unambiguous on every
# host, and adb has accepted multiple sources for a long time.
( cd "$STAGE" && adb push nativeLibraryDir avr Blink.ino build-blink.sh "$DEV" | tail -1 )
adb shell chmod 755 "$NLD"/*.so

echo "=== [3/5] symlink farm ==="
# Exactly the layout CompilerService builds at runtime.
adb shell mkdir -p "$TC/bin" "$TC/avr/bin" "$TC/libexec/gcc/avr/$GV"
link() { adb shell ln -sf "$NLD/$1" "$TC/$2"; }
link libavrgcc.so     bin/avr-gcc
link libavrgxx.so     bin/avr-g++
link libavrar.so      bin/avr-ar
link libavrranlib.so  bin/avr-ranlib
link libavrobjcopy.so bin/avr-objcopy
link libavrsize.so    bin/avr-size
link libavrnm.so      bin/avr-nm
link libavras.so      avr/bin/as
link libavrld.so      avr/bin/ld
link libavrnm.so      avr/bin/nm
for p in cc1 cc1plus lto1 collect2; do link "lib$p.so" "libexec/gcc/avr/$GV/$p"; done
link libltowrapper.so "libexec/gcc/avr/$GV/lto-wrapper"
link liblto_plugin.so "libexec/gcc/avr/$GV/liblto_plugin.so"

echo "=== [4/5] do the binaries even run? ==="
adb shell "LD_LIBRARY_PATH=$NLD $TC/bin/avr-gcc --version | head -1"
adb shell "LD_LIBRARY_PATH=$NLD $TC/avr/bin/as --version | head -1"
adb shell "LD_LIBRARY_PATH=$NLD $TC/avr/bin/ld --version | head -1"
# The reason we are on bionic rather than static musl: ld must dlopen the LTO
# plugin. If this line is missing, LTO is silently broken.
echo -n "    ld plugin support: "
adb shell "LD_LIBRARY_PATH=$NLD $TC/avr/bin/ld --help | grep -c -- '-plugin'"

echo "=== [5/5] build Blink on the phone ==="
WORK="$DEV/work"
adb shell mkdir -p "$WORK/core-src"
adb shell cp -r "$TC/cores" "$TC/variants" "$WORK/core-src/"
adb shell cp "$DEV/Blink.ino" "$WORK/Blink.ino"
BF="-B$TC/lib/gcc/avr/$GV/ -B$TC/avr/lib/ -B$TC/avr/bin/ -B$TC/libexec/gcc/avr/$GV/"
adb shell "
  export LD_LIBRARY_PATH=$NLD
  export TMPDIR=$WORK/tmp; mkdir -p \$TMPDIR
  OC_ROOT=$DEV OC_WORK=$WORK \
  OC_BFLAGS='$BF' \
  OC_GCC_EXEC_PREFIX=$TC/lib/gcc/ \
  OC_AR_PLUGIN=$NLD/liblto_plugin.so \
  OC_LDSCRIPT=$TC/avr/lib/ldscripts/avr5.xn \
  sh $DEV/build-blink.sh
" 2>&1 | tail -24

echo
echo "=== VERDICT ==="
GOT=$(adb shell "md5sum $WORK/build/Blink.ino.hex 2>/dev/null" | awk '{print $1}' | tr -d '\r')
echo "  device    : $GOT"
echo "  reference : $REF_MD5"
[ "$GOT" = "$REF_MD5" ] && echo "  *** BYTE-IDENTICAL ON HARDWARE ***" || { echo "  MISMATCH"; exit 1; }

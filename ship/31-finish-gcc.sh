#!/bin/bash
# ---------------------------------------------------------------------------
# 31-finish-gcc.sh — RECOVERY SCRIPT for an already-configured build tree.
#
# Not part of a clean run. 03-build-android.sh gets PIE right from the start by
# putting -fPIE/-pie in CFLAGS/CXXFLAGS/LDFLAGS, so a fresh build never needs
# this. Use it only to salvage an EXISTING $BUILD_DIR/android-gcc tree that was
# configured BEFORE that fix and died part-way through the link — it relinks in
# place and avoids a full reconfigure plus rebuild of everything compiled so far.
#
# Why the make-line override works HERE but not in 03-build-android.sh: this
# script runs make from inside the `gcc/` directory, so `NO_PIE_FLAG=` is a
# direct command-line variable. At the top level GCC sets `MAKEOVERRIDES=`,
# which deliberately stops command-line variables reaching the sub-makes, and
# the override silently does nothing (verified: -fno-PIE still on every compile
# line). Do not "fix" 03-build-android.sh by copying the line below into it.
#
# The link failure this recovers from:
#
# WHY: GCC 7.3.0's gcov.o/gcov-tool.o contain 64-bit loads (LDR x, [x,#:lo12:s])
# against a symbol lld places on a 4-byte boundary, so ld.lld rejects
# R_AARCH64_LDST64_ABS_LO12_NC ("improper alignment"). GNU bfd ld tolerates
# this; lld does not. gcov is a COVERAGE tool and is not part of the shipped
# toolchain (we ship cc1/cc1plus/lto1/collect2/lto-wrapper + drivers), so the
# fix is simply to build the targets we ship instead of the catch-all
# `all-gcc`, which drags gcov in via its `native` prerequisite list.
#
# This changes nothing about generated AVR code: gcov is never invoked in the
# compile pipeline, and every target artifact is lifted from Arduino verbatim.
# ---------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../build.conf"

B="$BUILD_DIR/android-gcc"
G="$B/gcc"
GV="$GCC_VERSION"
[ -d "$G" ] || { echo "FATAL: no android-gcc build dir; run 03-build-android.sh first"; exit 1; }

echo "=== building only the host binaries we ship (skipping gcov) ==="
cd "$G"
# Explicit per-program targets. Each has its own rule in gcc/Makefile (from
# c/Make-lang.in, cp/Make-lang.in, lto/Make-lang.in), so none of them pull in
# the `native` target's gcov prerequisites.
TARGETS="cc1 cc1plus lto1 collect2 lto-wrapper xgcc xg++"
# NO_PIE_FLAG= is THE critical fix (and applies to gcov too, so the gcov skip
# above is now just a size/scope decision, not a workaround).
#
# GCC's configure discovers that the host compiler accepts -no-pie and sets
#   NO_PIE_FLAG = -no-pie ;  LINKER += $(NO_PIE_FLAG)
# so every compiler binary links non-PIE. On Android that is fatal twice:
#   1. A non-PIE link makes lld emit COPY relocations for libc data (stdout,
#      stderr, ...) into .bss. bionic's copies land 4-byte aligned, so the
#      64-bit loads against them fail ld.lld's alignment check —
#      "R_AARCH64_LDST64_ABS_LO12_NC ... not aligned to 8 bytes". That is the
#      error that killed gcov, gcov-tool and xgcc.
#   2. Android's loader has REFUSED to exec non-PIE (ET_EXEC) binaries since
#      API 21, so even a successful non-PIE link would be unshippable.
# Clearing it restores clang's default PIE and produces ET_DYN binaries.
# Link-only change: no object was compiled with -fno-PIE, so nothing rebuilds.
#
# CC_FOR_BUILD/CXX_FOR_BUILD must be restated. gcc/Makefile line 771 says
#   CC_FOR_BUILD = $(CC)
# i.e. the NDK cross compiler. That is only ever correct because the TOP-LEVEL
# make passes `CC_FOR_BUILD=gcc CXX_FOR_BUILD=g++` as command-line variables,
# which outrank makefile assignments. Running make directly inside gcc/ loses
# them, so the build-side generator programs (genenums, gengenrtl, ...) get
# cross-compiled for aarch64 — they then fail on bionic's missing
# fflush_unlocked, and could not have been executed on the build host anyway.
# Restating them keeps generators native while the shipped binaries stay cross.
BUILD_VARS="CC_FOR_BUILD=gcc CXX_FOR_BUILD=g++ NO_PIE_CFLAGS_FOR_BUILD= NO_PIE_FLAG_FOR_BUILD="
# Purge any generator objects/programs a previous run cross-compiled by mistake.
rm -f build/*.o build/gen* 2>/dev/null
if ! make -j"$MAKE_JOBS" NO_PIE_FLAG= NO_PIE_CFLAGS= $BUILD_VARS $TARGETS > "$B/finish.log" 2>&1; then
  echo "--- finish.log tail ---"; tail -40 "$B/finish.log"
  echo "BUILD FAILED"; exit 1
fi

echo "=== built (Type MUST be DYN — ET_EXEC will not exec on Android) ==="
NDK_BIN="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/bin"
pie_fail=0
for f in $TARGETS; do
  [ -f "$G/$f" ] || continue
  t="$("$NDK_BIN/llvm-readelf" -h "$G/$f" | awk -F: '/Type:/{print $2}' | xargs)"
  printf '  %-12s %10s  %s\n' "$f" "$(stat -c%s "$G/$f")" "$t"
  case "$t" in DYN*) ;; *) pie_fail=1;; esac
done
[ "$pie_fail" = 0 ] || { echo "FATAL: some binaries are not PIE"; exit 1; }

# --- manual install ---------------------------------------------------------
# `make install-gcc` would rebuild gcov, so place the files ourselves in the
# exact layout GCC expects (and that 70-package.sh reads).
echo
echo "=== installing to $ANDROID_PREFIX ==="
LE="$ANDROID_PREFIX/libexec/gcc/avr/$GV"
mkdir -p "$LE" "$ANDROID_PREFIX/bin"
install -m755 "$G/cc1"         "$LE/cc1"
install -m755 "$G/cc1plus"     "$LE/cc1plus"
install -m755 "$G/lto1"        "$LE/lto1"
install -m755 "$G/collect2"    "$LE/collect2"
install -m755 "$G/lto-wrapper" "$LE/lto-wrapper"
install -m755 "$G/xgcc"        "$ANDROID_PREFIX/bin/avr-gcc"
install -m755 "$G/xg++"        "$ANDROID_PREFIX/bin/avr-g++"
PLUG="$(find "$B" -name 'liblto_plugin.so.0.0.0' | head -1)"
[ -n "$PLUG" ] && install -m755 "$PLUG" "$LE/liblto_plugin.so"

echo "=== installed layout ==="
ls -la "$LE"
ls -la "$ANDROID_PREFIX/bin" | grep -E 'avr-gcc|avr-g\+\+'
echo "FINISH-GCC DONE"

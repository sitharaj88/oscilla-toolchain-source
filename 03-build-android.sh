#!/bin/bash
# ---------------------------------------------------------------------------
# Canadian cross: build the SHIPPED avr toolchain.
#
#   --build  = x86_64-pc-linux-gnu     (this WSL box)
#   --host   = aarch64-linux-android   (the phone — bionic, NDK clang)
#   --target = avr                     (the microcontroller)
#
# Only HOST-side artifacts are built (`make all-host`). Every TARGET artifact —
# avr-libc, libgcc.a, crt*.o, specs, device-specs, ldscripts — is AVR machine
# code or plain text, is host-independent, and is lifted verbatim from
# Arduino's official distribution by 05-assemble.sh. That is both less work and
# strictly safer for byte-identity.
#
# Why bionic and not static musl: see the long note in build.conf. Short
# version: `ld` and `ar` must dlopen() liblto_plugin.so, and static libc cannot
# dlopen, and dropping the plugin changes LTO codegen.
# ---------------------------------------------------------------------------
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/build.conf"

NDK_BIN="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/bin"
[ -x "$NDK_BIN/clang" ] || { echo "NDK missing at $NDK_DIR — run 01-fetch.sh"; exit 1; }
[ -x "$NATIVE_PREFIX/avr/bin/as" ] || {
  echo "native avr binutils missing — run 02-build-native.sh first."
  echo "GCC's HAVE_AS_* configure probes must run against the real avr assembler,"
  echo "and the one we install for Android is an aarch64 binary this box cannot run."
  exit 1; }

mkdir -p "$BUILD_DIR" "$ANDROID_PREFIX"

# --- a runnable avr-gcc on PATH ---------------------------------------------
# In a Canadian cross the top level cannot use `./xgcc` for GCC_FOR_TARGET —
# xgcc is an aarch64 binary this box cannot execute — so configure falls back
# to whatever `avr-gcc` AC_CHECK_TOOL finds on PATH. gcc/Makefile then needs it
# for the `specs` rule ("Dump a specs file to make -B./ read these specs over
# installed ones", gcc/Makefile.in), and without one the build dies at the very
# end, after cc1plus has already linked:
#
#     avr-gcc -dumpspecs > tmp-specs
#     /bin/bash: line 1: avr-gcc: command not found
#     make[1]: *** [Makefile:1993: specs] Error 127
#
# Point it at OUR native build rather than letting it find Debian's gcc-avr
# package (GCC 5.4, unpatched): 02-build-native.sh is the same 7.3.0 sources,
# the same Atmel/arduino2 patches and the same configure line, so its
# -dumpspecs output is exactly what the aarch64 xgcc would print. (-dumpspecs
# emits the driver's built-in spec strings, which carry no host paths.) The
# shipped specs and device-specs are lifted from Arduino's distribution by
# 05-assemble.sh regardless, so this file never reaches the product — but a
# wrong-version compiler here is still not something to leave to chance.
export PATH="$NATIVE_PREFIX/bin:$PATH"
[ "$(command -v avr-gcc)" = "$NATIVE_PREFIX/bin/avr-gcc" ] || {
  echo "avr-gcc does not resolve to $NATIVE_PREFIX/bin — run 02-build-native.sh"; exit 1; }

# --- the cross compiler -----------------------------------------------------
export CC="$NDK_BIN/${ANDROID_TRIPLE}${ANDROID_API}-clang"
export CXX="$NDK_BIN/${ANDROID_TRIPLE}${ANDROID_API}-clang++"
export AR="$NDK_BIN/llvm-ar"
export RANLIB="$NDK_BIN/llvm-ranlib"
export NM="$NDK_BIN/llvm-nm"
export STRIP="$NDK_BIN/llvm-strip"
export OBJCOPY="$NDK_BIN/llvm-objcopy"
export OBJDUMP="$NDK_BIN/llvm-objdump"
export READELF="$NDK_BIN/llvm-readelf"
# Generator programs (genattrtab, gengtype, build-side libiberty, ...) run on
# the build machine, so they need the native compiler.
export CC_FOR_BUILD=gcc
export CXX_FOR_BUILD=g++
export BUILD_CC=gcc

# clang 19 (NDK r28) turns several long-standing C looseness warnings into hard
# errors by default. binutils 2.26 (2016) and GCC 7.3.0 (2018) predate that and
# do not compile without relaxing them. These affect only whether the HOST code
# compiles; they cannot influence generated AVR code.
CLANG_C_RELAX="-Wno-implicit-function-declaration -Wno-implicit-int \
-Wno-int-conversion -Wno-incompatible-pointer-types -Wno-deprecated-non-prototype"
# -O2 matches Arduino's own build flags. -g0 and -Wl,-s keep the payload down:
# these sources ship with full debug info otherwise and the memo's size budget
# assumes stripped binaries.
# -fPIE / -pie: forced, and the ordering is load-bearing. See the long note at
# the GCC build step below — GCC hard-codes `COMPILER += -fno-PIE` and
# `LINKER += -no-pie` into gcc/Makefile, and Android cannot execute a non-PIE
# 64-bit binary. These flags land AFTER GCC's on every command line, and for
# clang the last of a conflicting pair wins, so they override it.
export CFLAGS="-w -O2 -g0 -fPIE $CLANG_C_RELAX"
export CXXFLAGS="-w -O2 -g0 -std=gnu++11 -fPIE"
# max-page-size=16384: memo §5.3 / Play's 16 KB page requirement, enforced from
# 1 Feb 2027. NDK r28's lld already defaults to this; stating it makes the
# guarantee independent of the NDK version anyone rebuilds with.
export LDFLAGS="-Wl,-s -Wl,-z,max-page-size=16384 -pie"

# --- config.sub refresh -----------------------------------------------------
# 2016-era config.sub may not know the aarch64-linux-android triple. Refresh
# every copy in a tree rather than guessing which one configure consults.
refresh_config_sub() {
  local tree="$1"
  if sh "$(find "$tree" -name config.sub | head -1)" "$ANDROID_TRIPLE" >/dev/null 2>&1; then
    echo "    config.sub already understands $ANDROID_TRIPLE"
    return
  fi
  echo "    refreshing config.sub/config.guess in $(basename "$tree")"
  local base="https://git.savannah.gnu.org/cgit/config.git/plain"
  wget -qO "$DL_DIR/config.sub"   "$base/config.sub"
  wget -qO "$DL_DIR/config.guess" "$base/config.guess"
  find "$tree" -name config.sub   -exec cp "$DL_DIR/config.sub"   {} \;
  find "$tree" -name config.guess -exec cp "$DL_DIR/config.guess" {} \;
}

# ---------------------------------------------------------------------------
echo "############ [android 1/2] binutils $BINUTILS_LABEL ############"
if [ -f "$ANDROID_PREFIX/avr/bin/as" ]; then
  echo "  already installed, skipping"
else
  refresh_config_sub "$SRC_DIR/binutils"
  rm -rf "$BUILD_DIR/android-binutils"
  mkdir -p "$BUILD_DIR/android-binutils"
  cd "$BUILD_DIR/android-binutils"
  # --enable-plugins is stated explicitly: it is what makes `ld -plugin` and
  # `ar --plugin` work, and it is the single reason we are on bionic rather
  # than static musl. If it silently turned off, LTO would break.
  "$SRC_DIR/binutils/configure" \
      --prefix="$ANDROID_PREFIX" \
      --build=x86_64-pc-linux-gnu \
      --host="$ANDROID_TRIPLE" \
      --target=avr \
      --disable-nls --disable-doc --disable-werror \
      --enable-install-libiberty --enable-install-libbfd \
      --disable-libdecnumber --disable-gdb --disable-readline --disable-sim \
      --disable-gprof \
      --enable-plugins \
      > configure.log 2>&1 || { tail -40 configure.log; exit 1; }
  make -j"$MAKE_JOBS" > build.log 2>&1 || { tail -60 build.log; exit 1; }
  make install > install.log 2>&1 || { tail -40 install.log; exit 1; }
  echo "  installed"
fi

# ---------------------------------------------------------------------------
echo "############ [android 2/2] gcc $GCC_VERSION (host side only) ############"
if [ -f "$ANDROID_PREFIX/libexec/gcc/avr/$GCC_VERSION/cc1plus" ]; then
  echo "  already installed, skipping"
else
  refresh_config_sub "$SRC_DIR/gcc"
  mkdir -p "$BUILD_DIR/android-gcc"
  cd "$BUILD_DIR/android-gcc"
  # RESUMABLE. This stage is ~40 minutes of compilation, and make is already
  # incremental, so a tree that has been configured is reused rather than
  # discarded. Delete $BUILD_DIR/android-gcc by hand if you change any flag
  # above or in build.conf — configure bakes them into gcc/Makefile and a
  # resumed make will not notice.
  if [ -f config.status ]; then
    echo "  reusing configured tree (delete $BUILD_DIR/android-gcc to force)"
  else
  # --with-build-time-tools points GCC's assembler/linker feature probes at the
  # NATIVE avr binutils from 02-build-native.sh. Without it the probes cannot
  # run (the installed avr-as is an aarch64 binary), every HAVE_AS_* lands on
  # its conservative default, and codegen can silently drift away from the
  # Arduino IDE's.
  "$SRC_DIR/gcc/configure" \
      --enable-fixed-point \
      --enable-languages=c,c++ \
      --prefix="$ANDROID_PREFIX" \
      --build=x86_64-pc-linux-gnu \
      --host="$ANDROID_TRIPLE" \
      --target=avr \
      --with-build-time-tools="$NATIVE_PREFIX/avr/bin" \
      --disable-nls \
      --disable-libssp \
      --disable-libada \
      --disable-shared \
      --with-avrlibc=yes \
      --with-dwarf2 \
      --disable-doc \
      > configure.log 2>&1 || { tail -40 configure.log; exit 1; }
  fi
  # ---- the PIE problem, and why the fix is where it is --------------------
  #
  # GCC's configure notices the host compiler accepts -fno-PIE/-no-pie and
  # hard-codes them into gcc/Makefile:
  #
  #     COMPILER += $(NO_PIE_CFLAGS)      # -fno-PIE
  #     LINKER   += $(NO_PIE_FLAG)        # -no-pie
  #
  # On Android that is fatal twice over:
  #
  #   1. Android has refused to load non-PIE 64-bit executables since API 21,
  #      so every binary we ship would fail to exec.
  #   2. It never gets that far. Only a non-PIE link uses **copy relocations**,
  #      and lld gives the .bss copy it allocates for libc's `stdout`/`stderr`
  #      4-byte alignment while the code loads it with an 8-byte LDR:
  #        ld.lld: error: improper alignment for relocation
  #                R_AARCH64_LDST64_ABS_LO12_NC: 0x287844 is not aligned to 8
  #      Confirmed by disassembly: every one of those relocations resolves to
  #      an undefined `stdout`/`stderr` from libc.so. PIE has no copy
  #      relocations, so making the build PIE fixes the link and the runtime in
  #      one move.
  #
  # The fix is -fPIE/-pie appended to CFLAGS/CXXFLAGS/LDFLAGS at the top of
  # this script, NOT `make NO_PIE_CFLAGS= NO_PIE_FLAG=`, and NOT
  # --enable-default-pie:
  #
  #   * `make NO_PIE_CFLAGS=` looks like it should work and silently does not.
  #     GCC's top-level Makefile sets `MAKEOVERRIDES=` precisely to stop
  #     command-line variables reaching sub-makes, so the gcc/ sub-make never
  #     sees it. Verified: -fno-PIE was still on all 511 compile lines.
  #   * --enable-default-pie would also flip the *target* default, and changing
  #     AVR codegen is the one thing this rebuild must not do.
  #
  # What does work is ordering. GCC emits `$(COMPILER) -c $(ALL_CXXFLAGS)` and
  # `$(LINKER) $(LINKER_FLAGS) $(LDFLAGS)`, so our flags always land after
  # GCC's, and for clang the last of a conflicting pair wins.
  make -j"$MAKE_JOBS" all-host > build.log 2>&1 || { tail -80 build.log; exit 1; }
  make install-host > install.log 2>&1 || { tail -40 install.log; exit 1; }
  echo "  installed"
fi

# ---------------------------------------------------------------------------
# HARD GATE — every shipped binary must be ET_DYN (PIE), aarch64, and ask for
# bionic's loader. This is a hard failure, not a printout, because all three
# faults are invisible until the moment the app tries to exec on a real phone:
#
#   * ET_EXEC (non-PIE) — Android's loader has refused these since API 21. It
#     packages perfectly and then fails at exec time on the device, which is
#     the single most expensive place to discover it. See the PIE note above
#     for how a non-PIE link happens by default and why the fix is -fPIE/-pie
#     in CFLAGS/LDFLAGS rather than a make-line override.
#   * a glibc PT_INTERP (`/lib/ld-linux-aarch64.so.1`) — the spike's fatal flaw
#     (docs/ARDUINO_COMPILER.md §5.4): an absolute path that does not exist on
#     Android and cannot be created.
#   * p_align < 16 KB — Play enforces 16 KB page alignment from 1 Feb 2027.
#
# 05-assemble.sh re-checks all of this per renamed lib*.so; this catches it
# at the source, before anything is staged.
echo
echo "=== HARD GATE: ET_DYN / aarch64 / bionic interp / 16 KB align ==="
LE="$ANDROID_PREFIX/libexec/gcc/avr/$GCC_VERSION"
gate_fail=0
for f in "$ANDROID_PREFIX/bin/avr-gcc" \
         "$ANDROID_PREFIX/bin/avr-g++" \
         "$ANDROID_PREFIX/avr/bin/as" \
         "$ANDROID_PREFIX/avr/bin/ld" \
         "$ANDROID_PREFIX/avr/bin/ar" \
         "$ANDROID_PREFIX/bin/avr-objcopy" \
         "$LE/cc1" "$LE/cc1plus" "$LE/lto1" "$LE/collect2" "$LE/lto-wrapper" \
         "$LE/liblto_plugin.so"; do
  name="$(basename "$f")"
  if [ ! -f "$f" ]; then
    printf '  %-22s MISSING\n' "$name"; gate_fail=1; continue
  fi
  etype="$("$NDK_BIN/llvm-readelf" -h "$f" | awk -F: '/Type:/{print $2}' | xargs)"
  machine="$("$NDK_BIN/llvm-readelf" -h "$f" | awk -F: '/Machine:/{print $2}' | xargs)"
  interp="$("$NDK_BIN/llvm-readelf" -l "$f" 2>/dev/null | sed -n 's/.*program interpreter: \(.*\)\]/\1/p')"
  align="$("$NDK_BIN/llvm-readelf" -l "$f" 2>/dev/null | awk '/LOAD/{print $NF}' | sort -u | tail -1)"

  ok=1
  case "$etype"   in DYN*) ;; *) ok=0;; esac
  case "$machine" in *AArch64*|*aarch64*) ;; *) ok=0;; esac
  # A pure shared object (the LTO plugin) has no PT_INTERP, which is correct.
  # Anything we exec must name bionic's loader and nothing else.
  if [ "$name" != "liblto_plugin.so" ]; then
    [ "$interp" = "/system/bin/linker64" ] || ok=0
  else
    [ -z "$interp" ] || ok=0
  fi
  [ $((align)) -ge 16384 ] 2>/dev/null || ok=0

  [ "$ok" = 1 ] || gate_fail=1
  printf '  %-22s %-10s %-9s interp=%-20s align=%-8s %s\n' \
    "$name" "$etype" "$machine" "${interp:-<none>}" "$align" \
    "$([ "$ok" = 1 ] && echo PASS || echo '*** FAIL ***')"
done

if [ "$gate_fail" != 0 ]; then
  echo
  echo "FATAL: one or more binaries would not exec on Android. Not shippable."
  echo "       An ET_EXEC here means the PIE flags above did not take effect —"
  echo "       check that -fPIE/-pie survived into the link lines in build.log."
  exit 1
fi
echo "  ALL PASS"

echo
echo "=== DT_NEEDED (cc1plus) — libc++_shared.so must ship in jniLibs ==="
"$NDK_BIN/llvm-readelf" -d "$LE/cc1plus" | grep NEEDED
echo
du -sh "$ANDROID_PREFIX"

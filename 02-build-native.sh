#!/bin/bash
# ---------------------------------------------------------------------------
# Build a NATIVE x86_64 avr-gcc/binutils from the pinned Arduino sources.
#
# This is not shipped. It exists for two reasons:
#
#   1. GCC's configure probes the target assembler for features (HAVE_AS_*),
#      and the answers are baked into auto-host.h and can change codegen. In a
#      Canadian cross the installed avr-as is an aarch64 binary the build
#      machine cannot run, so the Android build is pointed at THIS toolchain
#      via --with-build-time-tools and gets the same answers Arduino's native
#      build got.
#
#   2. It is the dress rehearsal. Pairing these host binaries with Arduino's
#      lifted target artifacts must reproduce the reference Blink hex exactly
#      (04-refbuild.sh). If that holds, byte-identity is proven for our
#      sources + patches + configure line, with Android factored out of the
#      question entirely.
# ---------------------------------------------------------------------------
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/build.conf"

mkdir -p "$BUILD_DIR" "$NATIVE_PREFIX"

# Arduino's own flags, verbatim from binutils.build.bash / gcc.build.bash.
# -std=gnu++11 is ours: GCC 7.3.0's C++ predates C++17 and Ubuntu's g++ 15
# defaults to it, which rejects dynamic exception specifications and several
# other constructs the 2018 sources are full of.
BASE_CFLAGS="-w -O2 -g0"
BASE_CXXFLAGS="-w -O2 -g0 -std=gnu++11 -fpermissive"

# ---------------------------------------------------------------------------
echo "############ [native 1/2] binutils $BINUTILS_LABEL ############"
if [ -x "$NATIVE_PREFIX/bin/avr-as" ]; then
  echo "  already installed, skipping"
else
  rm -rf "$BUILD_DIR/native-binutils"
  mkdir -p "$BUILD_DIR/native-binutils"
  cd "$BUILD_DIR/native-binutils"
  CFLAGS="$BASE_CFLAGS" CXXFLAGS="$BASE_CXXFLAGS" LDFLAGS="-s" \
  "$SRC_DIR/binutils/configure" \
      --prefix="$NATIVE_PREFIX" \
      --target=avr \
      --disable-nls --disable-doc --disable-werror \
      --enable-install-libiberty --enable-install-libbfd \
      --disable-libdecnumber --disable-gdb --disable-readline --disable-sim \
      --enable-plugins \
      > configure.log 2>&1
  make -j"$MAKE_JOBS" > build.log 2>&1
  make install > install.log 2>&1
  echo "  installed: $("$NATIVE_PREFIX/bin/avr-as" --version | head -1)"
fi

# ---------------------------------------------------------------------------
echo "############ [native 2/2] gcc $GCC_VERSION (host side only) ############"
if [ -x "$NATIVE_PREFIX/bin/avr-gcc" ]; then
  echo "  already installed, skipping"
else
  rm -rf "$BUILD_DIR/native-gcc"
  mkdir -p "$BUILD_DIR/native-gcc"
  cd "$BUILD_DIR/native-gcc"
  # binutils is already in $NATIVE_PREFIX, so configure finds avr-as/avr-ld in
  # $prefix/avr/bin and its assembler feature probes actually run.
  PATH="$NATIVE_PREFIX/bin:$PATH" \
  CFLAGS="$BASE_CFLAGS" CXXFLAGS="$BASE_CXXFLAGS" LDFLAGS="-s" \
  "$SRC_DIR/gcc/configure" \
      --enable-fixed-point \
      --enable-languages=c,c++ \
      --prefix="$NATIVE_PREFIX" \
      --disable-nls \
      --disable-libssp \
      --disable-libada \
      --disable-shared \
      --with-avrlibc=yes \
      --with-dwarf2 \
      --disable-doc \
      --target=avr \
      > configure.log 2>&1
  # all-host / install-host: we never build target libgcc, because every target
  # artifact is lifted verbatim from Arduino's distribution (see 05-assemble.sh).
  PATH="$NATIVE_PREFIX/bin:$PATH" make -j"$MAKE_JOBS" all-host > build.log 2>&1
  PATH="$NATIVE_PREFIX/bin:$PATH" make install-host > install.log 2>&1
  echo "  installed: $("$NATIVE_PREFIX/bin/avr-gcc" --version | head -1)"
fi

echo
echo "=== native toolchain at $NATIVE_PREFIX ==="
ls "$NATIVE_PREFIX/libexec/gcc/avr/$GCC_VERSION/"
du -sh "$NATIVE_PREFIX"

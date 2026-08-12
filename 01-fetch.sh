#!/bin/bash
# ---------------------------------------------------------------------------
# Fetch every input the toolchain build needs. Idempotent: re-running only
# downloads what is missing. Run inside WSL:
#
#   wsl -d Ubuntu -- bash /mnt/c/.../tools/avr-toolchain/01-fetch.sh
# ---------------------------------------------------------------------------
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=build.conf
source "$HERE/build.conf"

mkdir -p "$DL_DIR" "$SRC_DIR" "$AVRTC_ROOT/ndk"

# --- host build dependencies ------------------------------------------------
need_pkgs=(build-essential bison flex texinfo gawk bzip2 xz-utils zip unzip file
           rsync wget curl python3 libgmp-dev libmpfr-dev libmpc-dev)
missing=()
for p in "${need_pkgs[@]}"; do
  dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "=== installing host packages: ${missing[*]}"
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}"
fi

# --- downloads --------------------------------------------------------------
fetch() {
  local url="$1" out="$DL_DIR/$2"
  if [ -s "$out" ]; then
    echo "    cached  $2"
  else
    echo "    fetch   $2"
    wget -q --show-progress -O "$out.part" "$url"
    mv "$out.part" "$out"
  fi
}

echo "=== [1/3] toolchain sources ==="
fetch "$BINUTILS_SRC_URL"   avr-binutils.tar.bz2
fetch "$GCC_SRC_URL"        "gcc-${GCC_VERSION}.tar.xz"
fetch "$GMP_SRC_URL"        "gmp-${GMP_VERSION}.tar.bz2"
fetch "$MPFR_SRC_URL"       "mpfr-${MPFR_VERSION}.tar.bz2"
fetch "$MPC_SRC_URL"        "mpc-${MPC_VERSION}.tar.gz"
fetch "$GCC_PATCH_URL"      "atmel-patches-gcc.${GCC_VERSION}-arduino2.patch"
fetch "$BINUTILS_PATCH_URL" 00-binutils-data_region_length.patch

echo "=== [2/3] Arduino prebuilt (source of all TARGET artifacts) + core ==="
# The spike already downloaded the aarch64 distribution. Its target artifacts
# (AVR machine code + text) are byte-identical to the x86_64 distribution's, so
# reuse it rather than pulling another 38 MB.
SPIKE_TAR="$REPO/tools/avr-spike/dl/avr-gcc-aarch64.tar"
if [ -s "$DL_DIR/arduino-avr-prebuilt.tar" ]; then
  echo "    cached  arduino-avr-prebuilt.tar"
elif [ -s "$SPIKE_TAR" ]; then
  echo "    reuse   tools/avr-spike/dl/avr-gcc-aarch64.tar"
  cp "$SPIKE_TAR" "$DL_DIR/arduino-avr-prebuilt.tar"
else
  fetch "$ARDUINO_AVR_PREBUILT_URL" arduino-avr-prebuilt.tar.bz2
  bunzip2 -k "$DL_DIR/arduino-avr-prebuilt.tar.bz2"
fi

SPIKE_CORE="$REPO/tools/avr-spike/dl/ArduinoCore-avr.tar.gz"
if [ -s "$DL_DIR/ArduinoCore-avr.tar.gz" ]; then
  echo "    cached  ArduinoCore-avr.tar.gz"
elif [ -s "$SPIKE_CORE" ]; then
  echo "    reuse   tools/avr-spike/dl/ArduinoCore-avr.tar.gz"
  cp "$SPIKE_CORE" "$DL_DIR/ArduinoCore-avr.tar.gz"
else
  fetch "$ARDUINO_CORE_URL" ArduinoCore-avr.tar.gz
fi

echo "=== [3/3] Android NDK $NDK_VERSION ==="
if [ -x "$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/bin/clang" ]; then
  echo "    cached  $NDK_DIR"
else
  fetch "$NDK_URL" "android-ndk-${NDK_VERSION}-linux.zip"
  echo "    unzip (this takes a minute)"
  unzip -q -o "$DL_DIR/android-ndk-${NDK_VERSION}-linux.zip" -d "$AVRTC_ROOT/ndk"
fi

# --- unpack sources ---------------------------------------------------------
echo "=== unpacking sources ==="
unpack() { # tarball, destdir, stripdir-glob
  local tb="$DL_DIR/$1" dst="$SRC_DIR/$2"
  if [ -d "$dst" ]; then echo "    present $2"; return; fi
  echo "    unpack  $2"
  rm -rf "$dst.tmp"; mkdir -p "$dst.tmp"
  tar -xf "$tb" -C "$dst.tmp"
  local inner; inner="$(find "$dst.tmp" -mindepth 1 -maxdepth 1 -type d | head -1)"
  mv "$inner" "$dst"; rm -rf "$dst.tmp"
}
unpack avr-binutils.tar.bz2            binutils
unpack "gcc-${GCC_VERSION}.tar.xz"     gcc
unpack "gmp-${GMP_VERSION}.tar.bz2"    gmp
unpack "mpfr-${MPFR_VERSION}.tar.bz2"  mpfr
unpack "mpc-${MPC_VERSION}.tar.gz"     mpc

if [ ! -d "$PREBUILT_DIR/avr" ]; then
  echo "    unpack  arduino prebuilt"
  mkdir -p "$PREBUILT_DIR"
  tar -xf "$DL_DIR/arduino-avr-prebuilt.tar" -C "$PREBUILT_DIR"
fi
if [ ! -d "$SRC_DIR/ArduinoCore-avr" ]; then
  unpack ArduinoCore-avr.tar.gz ArduinoCore-avr
fi

# --- apply patches (guarded so re-runs are safe) ----------------------------
echo "=== patching ==="
if [ ! -f "$SRC_DIR/binutils/.oscilla-patched" ]; then
  ( cd "$SRC_DIR/binutils"
    patch -p1 < "$DL_DIR/00-binutils-data_region_length.patch"
    touch .oscilla-patched )
  echo "    binutils: Arduino data_region_length patch applied"
else
  echo "    binutils: already patched"
fi

if [ ! -f "$SRC_DIR/gcc/.oscilla-patched" ]; then
  ( cd "$SRC_DIR/gcc"
    patch -p1 < "$DL_DIR/atmel-patches-gcc.${GCC_VERSION}-arduino2.patch"
    touch .oscilla-patched )
  echo "    gcc: Atmel 3.6.1 / arduino2 patch applied"
else
  echo "    gcc: already patched"
fi

# --- bionic fix: the host `gengtype` must not read the BUILD machine's config -
# GCC generates gengtype-lex.c by prepending an UNCONDITIONAL
# `#include "bconfig.h"` to flex's output (rule at gcc/Makefile.in:2775), and
# the 7.3.0 tarball ships a pre-generated gengtype-lex.c whose line 1 is that
# same include. bconfig.h pulls in auto-build.h — the *build* machine's config
# (x86_64 glibc) — even when the file is being compiled for the HOST with
# -DHOST_GENERATOR_FILE. The body of gengtype-lex.l gets this right
# (`#ifdef HOST_GENERATOR_FILE` -> config.h -> auto-host.h), but the prepended
# line is included first and wins.
#
# In a Canadian cross to bionic that is fatal. auto-build.h has
# `#define HAVE_FREAD_UNLOCKED 1` (true of glibc, false of bionic), so
# gcc/system.h rewrites every `fread` to `fread_unlocked`, and bionic did not
# add fread_unlocked until API 28 while we target 26:
#
#     ld.lld: error: undefined symbol: fread_unlocked
#     >>> referenced by gengtype-lex.c
#     >>>               gengtype-lex.o:(yylex(char const**))
#     make[1]: *** [Makefile:2785: gengtype] Error 1
#
# `gengtype` is a host-side tool for GCC's -fplugin support. We never ship it
# and never run it, but `make all-host` builds it, so the whole build stops
# there. (Dropping it via --disable-plugin is NOT an option: top-level
# configure ties plugin support to lto-plugin, and liblto_plugin.so is exactly
# what makes `-flto -fuse-linker-plugin` — and therefore byte-identity with the
# Arduino IDE — work. See build.conf.)
#
# Fix both copies so the include honours HOST_GENERATOR_FILE, mirroring what
# the .l body already does. This cannot affect generated AVR code: gengtype
# only emits GC-marking routines for GCC's own internal data structures.
if [ ! -f "$SRC_DIR/gcc/.oscilla-gengtype-bconfig" ]; then
  python3 - "$SRC_DIR/gcc" <<'PY'
import sys, pathlib
root = pathlib.Path(sys.argv[1])
guarded = ('#ifdef HOST_GENERATOR_FILE\n'
           '#include "config.h"\n'
           '#else\n'
           '#include "bconfig.h"\n'
           '#endif\n')

# 1. the pre-generated scanner shipped in the tarball
lex = root / "gcc" / "gengtype-lex.c"
txt = lex.read_text()
assert txt.startswith('#include "bconfig.h"\n'), "gengtype-lex.c line 1 unexpected"
lex.write_text(guarded + txt.split("\n", 1)[1])
print("    gcc: gengtype-lex.c include guarded")

# 2. the rule that would regenerate it if flex reruns
mk = root / "gcc" / "Makefile.in"
txt = mk.read_text()
old = """\t  echo '#include "bconfig.h"' > $@.tmp; \\\n"""
new = ("\t  echo '#ifdef HOST_GENERATOR_FILE'  > $@.tmp; \\\n"
       "\t  echo '#include \"config.h\"'      >> $@.tmp; \\\n"
       "\t  echo '#else'                      >> $@.tmp; \\\n"
       "\t  echo '#include \"bconfig.h\"'     >> $@.tmp; \\\n"
       "\t  echo '#endif'                     >> $@.tmp; \\\n")
assert old in txt, "gengtype-lex.c rule in Makefile.in unexpected"
mk.write_text(txt.replace(old, new, 1))
print("    gcc: Makefile.in gengtype-lex.c rule guarded")
PY
  touch "$SRC_DIR/gcc/.oscilla-gengtype-bconfig"
else
  echo "    gcc: gengtype-lex bconfig fix already applied"
fi

# GCC builds gmp/mpfr/mpc in-tree when they are symlinked into its source dir.
for lib in gmp mpfr mpc; do
  [ -e "$SRC_DIR/gcc/$lib" ] || ln -s "../$lib" "$SRC_DIR/gcc/$lib"
done
echo "    gcc: gmp/mpfr/mpc linked in-tree"

echo
echo "=== READY ==="
du -sh "$SRC_DIR"/* "$PREBUILT_DIR" "$NDK_DIR" 2>/dev/null || true

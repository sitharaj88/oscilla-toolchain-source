#!/bin/bash
# ---------------------------------------------------------------------------
# 00-prereqs.sh — host build deps + toolchain SOURCES (no NDK; musl path).
# Idempotent. Run in WSL Ubuntu (root):
#   wsl -d Ubuntu -- bash /mnt/c/.../tools/avr-toolchain/00-prereqs.sh
# ---------------------------------------------------------------------------
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/build.conf"

mkdir -p "$DL_DIR" "$SRC_DIR"

# --- host build dependencies ------------------------------------------------
# binutils-avr/gcc-avr/avr-libc: x86_64-hosted AVR tools that satisfy GCC's
# configure-time existence/feature probes for the Canadian cross. We do NOT run
# them for target-lib builds (we skip target libs and reuse Arduino's).
need_pkgs=(build-essential bison flex texinfo gawk bzip2 xz-utils unzip file
           rsync wget curl python3 binutils-avr gcc-avr avr-libc)
missing=()
for p in "${need_pkgs[@]}"; do
  dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "=== installing host packages: ${missing[*]}"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}"
fi

fetch() {
  local url="$1" out="$DL_DIR/$2"
  if [ -s "$out" ]; then echo "    cached  $2"; return; fi
  echo "    fetch   $2  <- $url"
  wget -q -O "$out.part" "$url"
  mv "$out.part" "$out"
}

echo "=== [1/2] toolchain sources ==="
fetch "$BINUTILS_SRC_URL"   avr-binutils.tar.bz2
fetch "$GCC_SRC_URL"        "gcc-${GCC_VERSION}.tar.xz"
fetch "$GMP_SRC_URL"        "gmp-${GMP_VERSION}.tar.bz2"
fetch "$MPFR_SRC_URL"       "mpfr-${MPFR_VERSION}.tar.bz2"
fetch "$MPC_SRC_URL"        "mpc-${MPC_VERSION}.tar.gz"
fetch "$GCC_PATCH_URL"      "atmel-patches-gcc.${GCC_VERSION}-arduino2.patch" || echo "    (gcc patch fetch failed; will fall back to vanilla)"
fetch "$BINUTILS_PATCH_URL" 00-binutils-data_region_length.patch || echo "    (binutils patch fetch failed)"

echo "=== [2/2] Arduino prebuilt (source of all TARGET artifacts) + core ==="
# Reuse the spike's already-extracted aarch64 avr tree at ~/avrspike/tc/avr for
# target libs. Also keep the tarball form for provenance.
SPIKE_TAR="$REPO/tools/avr-spike/dl/avr-gcc-aarch64.tar"
if [ -s "$DL_DIR/arduino-avr-prebuilt.tar" ]; then
  echo "    cached  arduino-avr-prebuilt.tar"
elif [ -s "$SPIKE_TAR" ]; then
  echo "    reuse   tools/avr-spike/dl/avr-gcc-aarch64.tar"
  cp "$SPIKE_TAR" "$DL_DIR/arduino-avr-prebuilt.tar"
fi
SPIKE_CORE="$REPO/tools/avr-spike/dl/ArduinoCore-avr.tar.gz"
if [ -s "$SPIKE_CORE" ]; then
  cp -n "$SPIKE_CORE" "$DL_DIR/ArduinoCore-avr.tar.gz" || true
  echo "    reuse   ArduinoCore-avr.tar.gz"
fi

# --- unpack sources ---------------------------------------------------------
echo "=== unpacking sources ==="
unpack() {
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

# --- apply Arduino/Atmel patches (byte-identical output) --------------------
echo "=== patching ==="
if [ -s "$DL_DIR/00-binutils-data_region_length.patch" ] && [ ! -f "$SRC_DIR/binutils/.oscilla-patched" ]; then
  ( cd "$SRC_DIR/binutils"
    patch -p1 < "$DL_DIR/00-binutils-data_region_length.patch" && touch .oscilla-patched ) \
    && echo "    binutils: data_region_length patch applied" \
    || echo "    binutils: patch FAILED (continuing vanilla)"
else
  echo "    binutils: no patch / already patched"
fi
if [ -s "$DL_DIR/atmel-patches-gcc.${GCC_VERSION}-arduino2.patch" ] && [ ! -f "$SRC_DIR/gcc/.oscilla-patched" ]; then
  ( cd "$SRC_DIR/gcc"
    patch -p1 < "$DL_DIR/atmel-patches-gcc.${GCC_VERSION}-arduino2.patch" && touch .oscilla-patched ) \
    && echo "    gcc: Atmel 3.6.1/arduino2 patch applied" \
    || echo "    gcc: patch FAILED (continuing vanilla)"
else
  echo "    gcc: no patch / already patched"
fi

echo
echo "=== SOURCES READY ==="
du -sh "$SRC_DIR"/* 2>/dev/null || true

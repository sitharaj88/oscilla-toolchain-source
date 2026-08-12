#!/bin/bash
# ---------------------------------------------------------------------------
# The dress rehearsal.
#
# Assemble the exact hybrid the product ships — OUR rebuilt host binaries plus
# Arduino's verbatim target artifacts — but with the x86_64 host binaries, and
# build Blink.ino with the spike's own build-blink.sh. The resulting hex must
# md5 to $REFERENCE_HEX_MD5.
#
# If this passes, then our source pins, the Atmel/Arduino patches, the
# configure line and the lifted target artifacts together reproduce Arduino IDE
# output byte for byte — with Android factored out of the question. Whatever
# the on-device run then does is a pure packaging/exec question, which the
# spike already answered.
# ---------------------------------------------------------------------------
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/build.conf"

HYBRID="$AVRTC_ROOT/refbuild"
TC="$HYBRID/avr"          # build-blink.sh expects the prefix at $OC_ROOT/avr
GV="$GCC_VERSION"
# Allow 05-assemble.sh to re-run this against the TRIMMED data tree, to prove
# the trim removed nothing the build actually touches.
DATA_SRC="${DATA_SRC:-$PREBUILT_DIR/avr}"
LABEL="${LABEL:-full Arduino target tree}"

echo "=== assembling hybrid toolchain ($LABEL) ==="
rm -rf "$HYBRID"; mkdir -p "$TC"

# 1. host side: everything we built ourselves
cp -a "$NATIVE_PREFIX"/. "$TC"/

# 2. target side: lifted verbatim, replacing whatever our host-only build left
rm -rf "$TC/lib/gcc/avr/$GV" "$TC/avr/include" "$TC/avr/lib"
mkdir -p "$TC/lib/gcc/avr" "$TC/avr"
cp -a "$DATA_SRC/lib/gcc/avr/$GV" "$TC/lib/gcc/avr/$GV"
cp -a "$DATA_SRC/avr/include"     "$TC/avr/include"
cp -a "$DATA_SRC/avr/lib"         "$TC/avr/lib"

echo "    host  : $("$TC/bin/avr-gcc" --version | head -1)"
echo "    as    : $("$TC/avr/bin/as" --version | head -1)"

# 3. the sketch + the Arduino core
WORK="$HYBRID/work"
mkdir -p "$WORK/core-src"
cp -a "$SRC_DIR/ArduinoCore-avr/cores"    "$WORK/core-src/"
cp -a "$SRC_DIR/ArduinoCore-avr/variants" "$WORK/core-src/"
cp "$REPO/tools/avr-spike/Blink.ino" "$WORK/Blink.ino"

# 4. build, through the same -B / GCC_EXEC_PREFIX / --plugin / -T plumbing the
#    Android packaging forces on us, so this rehearsal exercises that too.
echo
echo "=== building Blink.ino ==="
BF="-B$TC/lib/gcc/avr/$GV/ -B$TC/avr/lib/ -B$TC/avr/bin/ -B$TC/libexec/gcc/avr/$GV/"
PLUGIN="$TC/libexec/gcc/avr/$GV/liblto_plugin.so"
[ -f "$PLUGIN" ] || PLUGIN="$(find "$TC/libexec" -name 'liblto_plugin.so*' | head -1)"

OC_ROOT="$HYBRID" OC_WORK="$WORK" \
  OC_BFLAGS="$BF" \
  OC_GCC_EXEC_PREFIX="$TC/lib/gcc/" \
  OC_AR_PLUGIN="$PLUGIN" \
  OC_LDSCRIPT="$TC/avr/lib/ldscripts/avr5.xn" \
  sh "$REPO/tools/avr-spike/build-blink.sh" 2>&1 | tail -22

# 5. the verdict
echo
echo "=== VERDICT ==="
HEX="$WORK/build/Blink.ino.hex"
if [ ! -f "$HEX" ]; then echo "FAIL: no hex produced"; exit 1; fi
GOT="$(md5sum "$HEX" | cut -d' ' -f1)"
echo "  built     : $GOT"
echo "  reference : $REFERENCE_HEX_MD5"
if [ "$GOT" = "$REFERENCE_HEX_MD5" ]; then
  echo "  RESULT: *** BYTE-IDENTICAL to the Arduino-IDE reference ***"
else
  echo "  RESULT: MISMATCH"
  diff <(cat "$HEX") "$REPO/tools/avr-spike/out/pc/Blink.ino.hex" | head -20 || true
  exit 1
fi

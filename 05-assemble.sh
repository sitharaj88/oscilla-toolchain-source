#!/bin/bash
# ---------------------------------------------------------------------------
# Turn the two build outputs into the shippable payload for :arduino:toolchain.
#
#   jniLibs/arm64-v8a/lib*.so   every executable, renamed  (memo §5.3: Play's
#                               bundle validator rejects anything under lib/
#                               without a .so extension, and nativeLibraryDir
#                               is the ONLY directory an app may execve from)
#   assets/toolchain-data.zip   headers, archives, specs, linker scripts and
#                               the Arduino core — data, never executed
#
# The trim is gated: after trimming, the tree is rebuilt with 04-refbuild.sh
# and must still produce the reference hex. A trim that removes something the
# build touches fails the script rather than shipping.
# ---------------------------------------------------------------------------
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/build.conf"

GV="$GCC_VERSION"
NDK_BIN="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/bin"
SYSROOT_LIB="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android"
DATA="$STAGE_DIR/data"
LIBS="$STAGE_DIR/jniLibs/arm64-v8a"

# The generation string. Bump the trailing counter whenever the payload changes
# in a way that must invalidate an already-unpacked toolchain on a user device.
DATA_VERSION="${GV}-arduino7-bionic-1"

rm -rf "$STAGE_DIR"
mkdir -p "$DATA" "$LIBS"

# ===========================================================================
echo "############ [1/6] target data tree (trimmed to $AVR_DEVICE / $AVR_MULTILIB) ############"
SRC="$PREBUILT_DIR/avr"

# --- lib/gcc/avr/<ver> : specs, device-specs, the avr5 multilib only ---------
G_SRC="$SRC/lib/gcc/avr/$GV"
G_DST="$DATA/lib/gcc/avr/$GV"
mkdir -p "$G_DST"
cp -a "$G_SRC/$AVR_MULTILIB" "$G_DST/"
for d in include include-fixed device-specs; do
  [ -d "$G_SRC/$d" ] && cp -a "$G_SRC/$d" "$G_DST/"
done
[ -f "$G_SRC/specs" ] && cp -a "$G_SRC/specs" "$G_DST/"
# device-specs is kept WHOLE and deliberately: memo §6 note 1 — under -flto the
# driver re-invokes itself with the multilib name (specs-avr5) as well as the
# device name (specs-atmega328p), and it is only ~1 MB of small text files.
# What is NOT kept: the top-level (default avr2 multilib) libgcc.a/libgcov.a,
# ~6 MB that -mmcu=atmega328p can never reach, and every other multilib.

# --- avr/lib : avr5 multilib + linker scripts -------------------------------
mkdir -p "$DATA/avr/lib"
cp -a "$SRC/avr/lib/$AVR_MULTILIB" "$DATA/avr/lib/"
cp -a "$SRC/avr/lib/ldscripts"     "$DATA/avr/lib/"

# --- avr/include : all of avr-libc except unreachable device I/O headers ----
# avr/include/avr is 28 MB, almost entirely per-device io*.h that avr/io.h
# fans out to one of. Everything that is not a device header is kept.
cp -a "$SRC/avr/include" "$DATA/avr/include"
KEEP_RE="$(echo $AVR_KEEP_IO_HEADERS | tr ' ' '\n' | sed 's/\./\\./g' | paste -sd'|')"
DROPPED=0
while IFS= read -r f; do
  b="$(basename "$f")"
  if ! echo "$b" | grep -qE "^($KEEP_RE)$"; then rm -f "$f"; DROPPED=$((DROPPED+1)); fi
done < <(find "$DATA/avr/include/avr" -maxdepth 1 -name 'io*.h' ! -name 'io.h')
echo "    dropped $DROPPED unreachable device I/O headers"

# --- Arduino AVR core 1.8.6 -------------------------------------------------
mkdir -p "$DATA/cores" "$DATA/variants"
cp -a "$SRC_DIR/ArduinoCore-avr/cores/arduino"     "$DATA/cores/"
cp -a "$SRC_DIR/ArduinoCore-avr/variants/standard" "$DATA/variants/"

echo "    data tree: $(du -sh "$DATA" | cut -f1)"
du -sh "$DATA"/* | sed 's/^/      /'

# ===========================================================================
echo "############ [2/6] GATE: rebuild Blink against the TRIMMED tree ############"
# Uses the native host binaries; this is purely a completeness check on the
# trim. Byte-identity here means nothing the build touches was removed.
DATA_SRC="$DATA" LABEL="trimmed tree" bash "$HERE/04-refbuild.sh" | tail -6

# ===========================================================================
echo "############ [3/6] executables -> jniLibs/arm64-v8a/lib*.so ############"
LX="$ANDROID_PREFIX/libexec/gcc/avr/$GV"
put() { # source, shipped name
  [ -f "$1" ] || { echo "    MISSING $1"; exit 1; }
  cp "$1" "$LIBS/$2"
  "$NDK_BIN/llvm-strip" --strip-unneeded "$LIBS/$2" 2>/dev/null || true
  chmod 755 "$LIBS/$2"
  printf '    %-22s %8s KB  <- %s\n' "$2" "$(( $(stat -c%s "$LIBS/$2") / 1024 ))" "$(basename "$1")"
}
put "$ANDROID_PREFIX/bin/avr-gcc"     libavrgcc.so
put "$ANDROID_PREFIX/bin/avr-g++"     libavrgxx.so
put "$ANDROID_PREFIX/bin/avr-ar"      libavrar.so
put "$ANDROID_PREFIX/bin/avr-ranlib"  libavrranlib.so
put "$ANDROID_PREFIX/bin/avr-objcopy" libavrobjcopy.so
put "$ANDROID_PREFIX/bin/avr-size"    libavrsize.so
put "$ANDROID_PREFIX/bin/avr-nm"      libavrnm.so
put "$ANDROID_PREFIX/avr/bin/as"      libavras.so
put "$ANDROID_PREFIX/avr/bin/ld"      libavrld.so
put "$LX/cc1"                         libcc1.so
put "$LX/cc1plus"                     libcc1plus.so
put "$LX/lto1"                        liblto1.so
put "$LX/collect2"                    libcollect2.so
put "$LX/lto-wrapper"                 libltowrapper.so
put "$(find "$LX" -name 'liblto_plugin.so*' -type f | head -1)" liblto_plugin.so
# The one genuine third-party runtime: NDK clang++ links libc++ dynamically.
put "$SYSROOT_LIB/libc++_shared.so"   libc++_shared.so

# ===========================================================================
echo "############ [4/6] ELF audit ############"
FAIL=0
# Exactly two payload entries are genuine shared libraries rather than renamed
# executables, and only those two may lack a PT_INTERP. Naming them explicitly
# turns "no interpreter" from something the audit shrugs at into something it
# checks: a *missing* interpreter on cc1plus would mean a static or malformed
# link, which is precisely the class of fault this gate exists to catch.
NO_INTERP_OK=" liblto_plugin.so libc++_shared.so "
for f in "$LIBS"/*.so; do
  b="$(basename "$f")"
  # NB: no `grep` in these pipelines. Under `set -euo pipefail` a grep that
  # matches nothing exits 1, fails the whole pipeline, fails the assignment and
  # silently kills the script — which is exactly what happened on the first run
  # here, at libc++_shared.so (the first payload entry with no PT_INTERP). sed
  # -n prints nothing and still exits 0, so absence reads as an empty string.
  interp="$("$NDK_BIN/llvm-readelf" -l "$f" 2>/dev/null \
            | sed -n 's/.*\[Requesting program interpreter: \(.*\)\]/\1/p')"
  align="$("$NDK_BIN/llvm-readelf" -l "$f" 2>/dev/null \
            | awk '$1=="LOAD"{print $NF}' | sort -u | tail -1)"
  etype="$("$NDK_BIN/llvm-readelf" -h "$f" 2>/dev/null \
            | sed -n 's/^ *Type: *//p' | head -1)"

  # ET_EXEC has been unloadable on 64-bit Android since API 21 (memo §5.3).
  case "$etype" in
    DYN*) : ;;
    *) echo "    BAD TYPE    $b -> ${etype:-?} (must be ET_DYN/PIE)"; FAIL=1 ;;
  esac
  # An interpreter is fine only if it is Android's, which always exists.
  if [ -n "$interp" ]; then
    [ "$interp" = "/system/bin/linker64" ] || {
      echo "    BAD INTERP  $b -> $interp"; FAIL=1; }
  else
    case "$NO_INTERP_OK" in
      *" $b "*) : ;;
      *) echo "    BAD INTERP  $b -> none (an executable must name the loader)"; FAIL=1 ;;
    esac
  fi
  # 16 KB page alignment, memo §5.3.
  case "$align" in
    0x4000|0x10000) : ;;
    *) echo "    BAD ALIGN   $b -> $align"; FAIL=1 ;;
  esac
done
[ "$FAIL" = 0 ] || exit 1
echo "    all $(ls "$LIBS" | wc -l) files: ET_DYN, interpreter /system/bin/linker64"
echo "    (none for liblto_plugin.so / libc++_shared.so), p_align >= 16 KB"
echo "    DT_NEEDED across the payload:"
for f in "$LIBS"/*.so; do "$NDK_BIN/llvm-readelf" -d "$f" 2>/dev/null | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p'; done | sort -u | sed 's/^/      /'

# ===========================================================================
echo "############ [5/6] package ############"
ASSETS="$STAGE_DIR/assets"
mkdir -p "$ASSETS"
( cd "$DATA" && zip -q -r -9 "$ASSETS/toolchain-data.zip" . )
echo "$DATA_VERSION" > "$ASSETS/toolchain-data.version"
bash "$HERE/06-licenses.sh" "$ASSETS/licenses"

# ===========================================================================
echo "############ [6/6] install into the Gradle module ############"
mkdir -p "$JNILIBS_DIR" "$ASSETS_DIR"
rm -f "$JNILIBS_DIR"/*.so
cp "$LIBS"/*.so "$JNILIBS_DIR/"
rm -rf "$ASSETS_DIR/licenses"
cp -a "$ASSETS"/. "$ASSETS_DIR/"

echo
echo "=============================================================="
echo " PAYLOAD"
echo "=============================================================="
printf '  jniLibs (uncompressed) : %s\n' "$(du -sh "$LIBS" | cut -f1)"
printf '  data tree (unpacked)   : %s\n' "$(du -sh "$DATA" | cut -f1)"
printf '  toolchain-data.zip     : %s\n' "$(du -h "$ASSETS/toolchain-data.zip" | cut -f1)"
printf '  installed size on disk : %s\n' \
  "$(( ($(du -sb "$LIBS" | cut -f1) + $(du -sb "$DATA" | cut -f1)) / 1048576 )) MB"
# What the download actually costs: the APK deflates jniLibs even with
# useLegacyPackaging, and the zip asset is already compressed.
JL_Z=$(cd "$LIBS" && zip -q -r -9 - . | wc -c)
printf '  download (compressed)  : %s MB  (jniLibs %s MB + data zip %s MB)\n' \
  "$(( (JL_Z + $(stat -c%s "$ASSETS/toolchain-data.zip")) / 1048576 ))" \
  "$(( JL_Z / 1048576 ))" \
  "$(( $(stat -c%s "$ASSETS/toolchain-data.zip") / 1048576 ))"
echo "  generation             : $DATA_VERSION"

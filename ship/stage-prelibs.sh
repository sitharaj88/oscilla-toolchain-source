#!/bin/bash
# Stage the ALREADY-BUILT bionic binutils (+ NDK libc++) under the repo so the
# Windows-side APK builder can pick them up, to exec-prove the gate while the
# GCC half is still compiling. Writes to a scratch dir, NOT to the module.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../build.conf"
OUT="$HERE/exectest/prelibs"
rm -rf "$OUT"; mkdir -p "$OUT"
NDK_BIN="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/bin"
LIBCXX="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so"

cp "$ANDROID_PREFIX/bin/avr-ld" "$OUT/libavrld.so"
cp "$ANDROID_PREFIX/bin/avr-as" "$OUT/libavras.so"
cp "$LIBCXX"                    "$OUT/libc++_shared.so"

echo "=== staged (must be DYN + interp=/system/bin/linker64 + align>=0x4000) ==="
for f in "$OUT"/*.so; do
  t="$("$NDK_BIN/llvm-readelf" -h "$f" | awk -F: '/Type:/{print $2}' | xargs)"
  i="$("$NDK_BIN/llvm-readelf" -l "$f" | awk '/interpreter/{print $NF}' | tr -d ']')"
  a="$("$NDK_BIN/llvm-readelf" -l "$f" | awk '/LOAD/{print $NF}' | sort -u | tail -1)"
  printf '  %-20s %-10s %-22s interp=%s align=%s\n' \
     "$(basename "$f")" "$(stat -c%s "$f")" "$t" "${i:-<none>}" "$a"
done
echo "PRELIBS READY: $OUT"

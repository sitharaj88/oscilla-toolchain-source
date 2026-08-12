#!/bin/bash
# Is the build producing non-PIE (ET_EXEC) binaries? Android's loader REFUSES
# to exec non-PIE since API 21, and non-PIE is what forces the copy relocations
# that trigger the R_AARCH64_LDST64_ABS_LO12_NC alignment failure.
NDK=/root/avrtc/ndk/android-ndk-r28c/toolchains/llvm/prebuilt/linux-x86_64
RE="$NDK/bin/llvm-readelf"
echo "=== ELF type of already-built ANDROID binutils (must be DYN=PIE) ==="
for f in /root/avrtc/out/android/bin/avr-ld /root/avrtc/out/android/bin/avr-as \
         /root/avrtc/out/android/bin/avr-objcopy; do
  [ -f "$f" ] || continue
  t="$("$RE" -h "$f" | awk -F: '/Type:/{print $2}' | xargs)"
  i="$("$RE" -l "$f" | awk '/interpreter/{print $NF}' | tr -d ']')"
  printf '  %-20s %-28s interp=%s\n' "$(basename "$f")" "$t" "${i:-<none>}"
done
echo
echo "=== does the android gcc Makefile inject -fno-PIE? ==="
grep -m3 -nE '^NO_PIE_CFLAGS|^NO_PIE_FLAG' /root/avrtc/build/android-gcc/gcc/Makefile 2>/dev/null || echo "  (not found)"
echo "=== was gcc.o compiled -fno-PIE? ==="
grep -m1 -o '\-fno-PIE' /root/avrtc/build/android-gcc/gcc/build.log 2>/dev/null \
  && echo "  YES: -fno-PIE present in android gcc build" || echo "  no -fno-PIE seen in build.log"
echo
echo "=== what the NDK clang defaults to (sanity) ==="
echo 'int main(){return 0;}' > /tmp/p.c
"$NDK/bin/aarch64-linux-android26-clang" -O2 /tmp/p.c -o /tmp/p.out 2>/dev/null \
  && "$RE" -h /tmp/p.out | awk -F: '/Type:/{print "  default clang link ->" $2}'

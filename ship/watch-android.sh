#!/bin/bash
# Wait until the concurrent owner build produces the Android cc1plus, or fails.
# Emits ONE terminal line then exits. Non-invasive: only reads.
CC1PLUS=/root/avrtc/out/android/libexec/gcc/avr/7.3.0/cc1plus
AGCC_LOG=/root/avrtc/build/android-gcc/build.log
ABU_LOG=/root/avrtc/build/android-binutils/build.log
deadline=$(( $(date +%s) + 3300 ))   # 55 min cap
while :; do
  if [ -f "$CC1PLUS" ]; then echo "ANDROID_READY cc1plus present $(ls -la "$CC1PLUS" | awk '{print $5}') bytes"; exit 0; fi
  # detect a hard failure in either android build log
  for L in "$ABU_LOG" "$AGCC_LOG"; do
    if [ -f "$L" ] && grep -qiE 'Error [0-9]+|configure: error|fatal error|No such file' "$L" 2>/dev/null; then
      # only real if the corresponding make is no longer running
      if ! pgrep -f 'android-(binutils|gcc)|src/gcc/configure|src/binutils/configure' >/dev/null 2>&1; then
        echo "ANDROID_BUILD_FAILED see $L"; tail -5 "$L"; exit 1
      fi
    fi
  done
  if [ "$(date +%s)" -gt "$deadline" ]; then echo "WATCH_TIMEOUT android cc1plus not ready after 55m"; exit 2; fi
  sleep 60
done

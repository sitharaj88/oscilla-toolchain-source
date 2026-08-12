#!/bin/bash
# One-shot waiter: cc1plus INSTALLED into the android prefix, or the build died.
# Read-only; never touches the concurrent build.
CC1PLUS=/root/avrtc/out/android/libexec/gcc/avr/7.3.0/cc1plus
LOG=/root/avrtc/build/android-gcc/build.log
deadline=$(( $(date +%s) + 3300 ))
while :; do
  [ -f "$CC1PLUS" ] && { echo "CC1PLUS_INSTALLED $(stat -c%s "$CC1PLUS") bytes"; exit 0; }
  if ! pgrep -f 'make -j' >/dev/null 2>&1; then
    # no make running: either finished-without-install, or failed
    if grep -qE '\*\*\* \[.*\] Error [0-9]+' "$LOG" 2>/dev/null; then
      echo "BUILD_FAILED $(grep -E '\*\*\* \[.*\] Error [0-9]+' "$LOG" | tail -2 | tr '\n' ' ')"; exit 1
    fi
    echo "MAKE_STOPPED no make running and cc1plus absent — check install-host step"; exit 3
  fi
  [ "$(date +%s)" -gt "$deadline" ] && { echo "WATCH_TIMEOUT 55m"; exit 2; }
  sleep 60
done

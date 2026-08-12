#!/bin/bash
# Report the device-independent byte-identity proof (x86_64 native hybrid).
H=/root/avrtc/refbuild/work/build/Blink.ino.hex
REF=e52c115ebdc2de4a3b0d2668011e1dce
if [ -f "$H" ]; then
  GOT="$(md5sum "$H" | cut -d' ' -f1)"
  echo "hex bytes : $(wc -c < "$H")"
  echo "built     : $GOT"
  echo "reference : $REF"
  [ "$GOT" = "$REF" ] && echo "RESULT: *** BYTE-IDENTICAL ***" || echo "RESULT: MISMATCH"
  ls -la /root/avrtc/refbuild/work/build/Blink.ino.elf 2>/dev/null
else
  echo "no refbuild hex yet"
  ls -la /root/avrtc/refbuild/work/build 2>/dev/null | head
  echo "--- is 04-refbuild running? ---"
  pgrep -af 'refbuild|build-blink' | grep -v pgrep | head -3 || echo "  (not running)"
fi

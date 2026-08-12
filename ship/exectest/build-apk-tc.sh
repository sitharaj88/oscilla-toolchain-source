#!/bin/bash
# Build the release-shaped exec-proof APK by hand, shipping the REAL rebuilt
# toolchain lib*.so. Runs in Git Bash (native Windows SDK/NDK tools).
set -e
export MSYS_NO_PATHCONV=1
HERE="$(cd "$(dirname "$0")" && pwd)"
SDK="/c/Users/ASUS/AppData/Local/Android/Sdk"
BT="$SDK/build-tools/35.0.0"
PLATFORM="$SDK/platforms/android-35/android.jar"
# Source the shipped libs staged by 70-package.sh. Module is :arduino:toolchain
# (the single source of truth; feature/arduino-compiler was a deleted duplicate).
# JNILIBS/LIBS can be overridden to exec-prove a subset before the full
# toolchain exists (e.g. the binutils half while GCC is still compiling).
JNILIBS="${JNILIBS:-/c/Users/ASUS/Documents/electronic_simulator/arduino/toolchain/src/main/jniLibs/arm64-v8a}"
LIBS="${LIBS:-libavrld.so libcc1plus.so libavras.so libc++_shared.so}"

OUT="$HERE/out"; rm -rf "$OUT"; mkdir -p "$OUT/lib/arm64-v8a"
w() { cygpath -w "$1"; }

echo "=== 1. gather toolchain libs (representative exec-proof set) ==="
echo "    from: $JNILIBS"
for l in $LIBS; do
  if [ -f "$JNILIBS/$l" ]; then cp "$JNILIBS/$l" "$OUT/lib/arm64-v8a/$l"; echo "    + $l ($(stat -c%s "$JNILIBS/$l") B)"; \
  else echo "    !! MISSING $l — run 70-package.sh first"; exit 1; fi
done

echo "=== 2. javac + d8 -> classes.dex ==="
JAVAC="/c/Program Files/Android/Android Studio/jbr/bin/javac.exe"
mkdir -p "$OUT/classes"
"$JAVAC" -source 8 -target 8 -nowarn -bootclasspath "$(w "$PLATFORM")" \
  -d "$(w "$OUT/classes")" "$(w "$HERE/ExecTestTC.java")" 2>&1 | grep -v "bootstrap class path" || true
"$BT/d8.bat" --min-api 26 --output "$(w "$OUT")" \
  "$(w "$OUT/classes/com/oscilla/tcexec/ExecTestTC.class")"

echo "=== 3. aapt2 link (release manifest, debuggable removed) ==="
"$BT/aapt2.exe" link -I "$(w "$PLATFORM")" \
  --manifest "$(w "$HERE/AndroidManifest.xml")" \
  --min-sdk-version 26 --target-sdk-version 35 \
  -o "$(w "$OUT/base.apk")"

echo "=== 4. add native libs (stored) + dex ==="
cd "$OUT"
python - "$(w "$OUT/base.apk")" "$(w "$OUT/lib/arm64-v8a")" "$(w "$OUT/classes.dex")" <<'PY'
import sys, os, zipfile
apk, libdir, dex = sys.argv[1], sys.argv[2], sys.argv[3]
with zipfile.ZipFile(apk, 'a', zipfile.ZIP_STORED) as z:
    for f in sorted(os.listdir(libdir)):
        z.write(os.path.join(libdir, f), 'lib/arm64-v8a/' + f)
    z.write(dex, 'classes.dex')
    for i in z.infolist():
        print(f"  ctype={i.compress_type} {i.file_size:>10}  {i.filename}")
PY

echo "=== 5. zipalign + sign ==="
"$BT/zipalign.exe" -f -p 4 "$(w "$OUT/base.apk")" "$(w "$OUT/aligned.apk")"
KS="$HOME/.android/debug.keystore"
"$BT/apksigner.bat" sign --ks "$(w "$KS")" --ks-pass pass:android --key-pass pass:android \
  --ks-key-alias androiddebugkey --out "$(w "$OUT/tcexec.apk")" "$(w "$OUT/aligned.apk")"
ls -la "$OUT/tcexec.apk"
echo "APK READY: $OUT/tcexec.apk"

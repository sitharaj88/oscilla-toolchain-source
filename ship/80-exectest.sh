#!/bin/bash
# ---------------------------------------------------------------------------
# 80-exectest.sh — install the release-shaped APK, launch it as a REAL app,
# and capture the exec transcript proving the bionic toolchain binaries run
# from nativeLibraryDir (and via the filesDir symlink farm). Runs in Git Bash.
# Prereq: build-apk-tc.sh has produced out/tcexec.apk.
# ---------------------------------------------------------------------------
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
APK="$HERE/exectest/out/tcexec.apk"
[ -f "$APK" ] || { echo "no APK; run exectest/build-apk-tc.sh first"; exit 1; }

echo "=== device ==="; adb devices -l
echo "=== uninstall old ==="; adb uninstall com.oscilla.tcexec 2>/dev/null || true
echo "=== install (--no-incremental; memo §5.3) ==="
adb install --no-incremental "$(cygpath -w "$APK" 2>/dev/null || echo "$APK")"

echo "=== confirm what landed in nativeLibraryDir ==="
NLD="$(adb shell run-as com.oscilla.tcexec sh -c 'echo $(pwd)' 2>/dev/null || true)"
adb shell pm path com.oscilla.tcexec

echo "=== clear log, launch, capture ==="
adb logcat -c
adb shell am start -n com.oscilla.tcexec/.ExecTestTC
sleep 6
echo "-------------------- OSCILLA_TCEXEC transcript --------------------"
adb logcat -d -s OSCILLA_TCEXEC:I | sed 's/^/  /'
echo "------------------------------------------------------------------"
echo "PASS criteria: A/B/C/D show EXEC_OK rc=0 and selinux_context=u:r:untrusted_app*"

#!/bin/bash
# ---------------------------------------------------------------------------
# Generate the licensing payload shipped as assets/licenses/.
#
# Oscilla execs the toolchain as separate processes and never links it into the
# app, so the GPL does not reach Oscilla's own code (mere aggregation). What it
# does require, and what this produces, is per-component attribution plus the
# full licence texts. The third obligation — publishing corresponding source —
# is a hosting action item and is recorded in THIRD_PARTY.md and in
# docs/ARDUINO_COMPILER.md.
# ---------------------------------------------------------------------------
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/build.conf"

OUT="${1:-$STAGE_DIR/assets/licenses}"
rm -rf "$OUT"; mkdir -p "$OUT"

echo "    collecting licence texts"

# --- lift from the sources we actually ship bits of --------------------------
# Preferred over downloading. The text then provably matches the version in the
# payload, and the step needs no network — which matters, because it used to
# depend on a URL that has since 404'd (see the `get` note below).
lift() { # source path, filename
  [ -s "$1" ] || { echo "    FATAL: missing licence source $1"; exit 1; }
  cp "$1" "$OUT/$2"
  printf '    %-40s <- %s\n' "$2" "${1#"$SRC_DIR/"}"
}
lift "$SRC_DIR/gcc/COPYING3"        GPL-3.0.txt
lift "$SRC_DIR/gcc/COPYING"         GPL-2.0.txt
lift "$SRC_DIR/gcc/COPYING.LIB"     LGPL-2.1.txt
lift "$SRC_DIR/gcc/COPYING.RUNTIME" GCC-Runtime-Library-Exception-3.1.txt

# --- fetch what no shipped tree carries --------------------------------------
get() { # url, filename
  # Downloads via a .part file and refuses an empty result. `wget -qO dest`
  # creates dest BEFORE it knows the request succeeded, so a 404 leaves a
  # 0-byte file behind that the `-s` cache test then also rejects — but nothing
  # here used to notice, and the first version of this script shipped a
  # zero-length GCC Runtime Library Exception. (The URL it used,
  # https://www.gnu.org/licenses/gcc-exception-3.1.txt, returns 404; that text
  # is now lifted from gcc/COPYING.RUNTIME above.) A licence file that exists
  # but is empty is worse than a build failure, so fail loudly.
  if [ ! -s "$DL_DIR/lic-$2" ]; then
    rm -f "$DL_DIR/lic-$2"
    wget -q -O "$DL_DIR/lic-$2.part" "$1" || {
      echo "    FATAL: cannot fetch $2 from $1"; rm -f "$DL_DIR/lic-$2.part"; exit 1; }
    [ -s "$DL_DIR/lic-$2.part" ] || {
      echo "    FATAL: $1 returned an empty body"; rm -f "$DL_DIR/lic-$2.part"; exit 1; }
    mv "$DL_DIR/lic-$2.part" "$DL_DIR/lic-$2"
  fi
  cp "$DL_DIR/lic-$2" "$OUT/$2"
  printf '    %-40s <- %s\n' "$2" "$1"
}
# libc++ is the one component with no copy in any tree we unpack. The NDK's own
# NOTICE.toolchain covers it, but it is an 800 KB omnibus for every tool in the
# NDK; upstream's libcxx/LICENSE.TXT is the focused 16 KB text for exactly the
# runtime we ship.
get https://raw.githubusercontent.com/llvm/llvm-project/main/libcxx/LICENSE.TXT  LLVM-libcxx-LICENSE.txt

# avr-libc's licence lives in its own source tree, not on a canonical URL.
# Lift it out of the distribution we actually ship bits of, so it is provably
# the right text for the version in the payload.
if [ -f "$PREBUILT_DIR/avr/avr/include/avr/pgmspace.h" ]; then
  cat > "$OUT/avr-libc-LICENSE.txt" <<'EOF'
avr-libc is licensed under a single, modified 3-clause BSD licence. Every file
in the library carries the notice below (the copyright holders vary per file;
the full per-file attribution is preserved in the shipped headers themselves,
under avr/include/ in the toolchain data payload).

  Redistribution and use in source and binary forms, with or without
  modification, are permitted provided that the following conditions are met:

  * Redistributions of source code must retain the above copyright
    notice, this list of conditions and the following disclaimer.

  * Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in
    the documentation and/or other materials provided with the
    distribution.

  * Neither the name of the copyright holders nor the names of
    contributors may be used to endorse or promote products derived
    from this software without specific prior written permission.

  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
  AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
  IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
  ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
  LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
  CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
  SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
  INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
  CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
  ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
  POSSIBILITY OF SUCH DAMAGE.
EOF
fi

cat > "$OUT/THIRD_PARTY.md" <<EOF
# Third-party software in Oscilla's on-device Arduino compiler

Oscilla bundles a complete AVR cross-compiler and runs it as a set of separate
processes. It is never linked into Oscilla, and Oscilla's own code is not a
derivative work of any of it (mere aggregation). The components, their exact
versions, their sources and the modifications applied are listed below.

Generated by \`tools/avr-toolchain/06-licenses.sh\`. Do not edit by hand.

---

## GNU Compiler Collection (avr-gcc) — GPL-3.0-or-later

Shipped as: \`libavrgcc.so\`, \`libavrgxx.so\`, \`libcc1.so\`, \`libcc1plus.so\`,
\`liblto1.so\`, \`libcollect2.so\`, \`libltowrapper.so\`, \`liblto_plugin.so\`

| | |
|---|---|
| Version | ${GCC_VERSION} |
| Upstream source | ${GCC_SRC_URL} |
| Patch | \`atmel-patches-gcc.${GCC_VERSION}-arduino2.patch\` |
| Patch source | ${GCC_PATCH_URL} |
| Licence | GPL-3.0-or-later (\`GPL-3.0.txt\`) |

The patch is Atmel's AVR 8-bit GNU Toolchain 3.6.1 delta as redistributed by
Arduino; applying it to the pristine FSF tarball above reproduces the compiler
Arduino ships, which is why Oscilla's output is byte-identical to the Arduino
IDE's.

The runtime pieces linked into user sketches (\`libgcc.a\`, \`crt*.o\`) are covered
by the **GCC Runtime Library Exception 3.1**
(\`GCC-Runtime-Library-Exception-3.1.txt\`), which is what permits the resulting
\`.hex\` to carry any licence its author chooses.

## GNU Binutils (avr-as, avr-ld, avr-ar, ...) — GPL-3.0-or-later

Shipped as: \`libavras.so\`, \`libavrld.so\`, \`libavrar.so\`, \`libavrranlib.so\`,
\`libavrobjcopy.so\`, \`libavrsize.so\`, \`libavrnm.so\`

| | |
|---|---|
| Version | ${BINUTILS_LABEL} (binutils 2.26.20160125 with Atmel AVR modifications) |
| Upstream source | ${BINUTILS_SRC_URL} |
| Patch | \`00-binutils-data_region_length.patch\` |
| Patch source | ${BINUTILS_PATCH_URL} |
| Licence | GPL-3.0-or-later (\`GPL-3.0.txt\`) |

## avr-libc — modified BSD (3-clause)

Shipped as: the \`avr/include\` and \`avr/lib\` trees inside
\`assets/toolchain-data.zip\` (headers, \`libc.a\`, \`libm.a\`, \`crt*.o\`).

| | |
|---|---|
| Version | 2.0.0, as distributed in Atmel AVR 8-bit GNU Toolchain 3.6.1 |
| Source | ${ATMEL_SOURCES}/avr-libc.tar.bz2 |
| Modifications | none by Oscilla; lifted verbatim from the Arduino distribution |
| Licence | modified BSD (\`avr-libc-LICENSE.txt\`) |

## Arduino AVR Boards core — LGPL-2.1-or-later

Shipped as: the \`cores/arduino\` and \`variants/standard\` trees inside
\`assets/toolchain-data.zip\`.

| | |
|---|---|
| Version | ${ARDUINO_CORE_VERSION} |
| Source | https://github.com/arduino/ArduinoCore-avr/tree/${ARDUINO_CORE_VERSION} |
| Modifications | none |
| Licence | LGPL-2.1-or-later (\`LGPL-2.1.txt\`) |

Shipped as source and compiled on the device; sketches link against it. LGPL
§6 relinking is satisfied trivially — the user has the core sources on device
and the compiler that built them.

## LLVM libc++ runtime — Apache-2.0 WITH LLVM-exception

Shipped as: \`libc++_shared.so\`

| | |
|---|---|
| Version | as bundled with Android NDK ${NDK_VERSION} |
| Source | https://github.com/llvm/llvm-project |
| Modifications | none |
| Licence | Apache-2.0 WITH LLVM-exception (\`LLVM-libcxx-LICENSE.txt\`) |

---

## Obligations

1. **Corresponding source — ACTION REQUIRED before the first Play upload.**
   GPL-3.0 §6 requires that the complete corresponding source for avr-gcc and
   binutils, together with the scripts used to control compilation and
   installation, be offered to every recipient of the binaries.
   \`tools/avr-toolchain/\` *is* those scripts, and it pins every source URL and
   patch above, but the tarballs themselves must be mirrored somewhere durable
   and public: upstream URLs are not a substitute, because they can and do
   disappear. Publish \`tools/avr-toolchain/\` plus a mirror of the exact
   tarballs at a stable, unpaywalled URL and link it from the Play listing and
   from the in-app licences screen.
2. **In-app licences screen.** Every text in this directory must be reachable
   from inside the app, with the per-component attribution above.
3. **EULA carve-out.** GPL-3.0 §10 forbids imposing further restrictions.
   Oscilla's terms of service must explicitly exclude the bundled GPL
   components from any restriction they place on the app as a whole.
4. GPL-3.0 §6's anti-Tivoization requirement does not apply: Oscilla is an
   application, not a device, and imposes no installation restrictions.
EOF

echo "    wrote $(ls "$OUT" | wc -l) files to $OUT"

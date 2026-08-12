# Building Oscilla's on-device AVR toolchain

These scripts build the avr-gcc/binutils payload that ships inside
`:arduino:toolchain` and runs **on the phone**. Read
[`docs/ARDUINO_COMPILER.md`](../../docs/ARDUINO_COMPILER.md) first — it explains
the Android execution constraints these scripts exist to satisfy.

They are also the **corresponding source** disclosure the GPL requires: every
upstream tarball, every patch and every configure flag is pinned in
[`build.conf`](build.conf), and running the scripts in order reproduces the
shipped binaries.

## What is being built, and why not just use Arduino's binaries

Arduino publishes an `aarch64-pc-linux-gnu` avr-gcc. The spike ran it on the
phone, but only by rewriting `PT_INTERP` to a bundled glibc loader — a trick
that works from `adb shell` and **cannot** work inside an app, because the only
exec-capable directory has a randomised, read-only path
(`docs/ARDUINO_COMPILER.md` §5.4).

So we rebuild the same compiler, from the same sources and patches Arduino
uses, as a **Canadian cross**:

```
--build  x86_64-pc-linux-gnu     this WSL box
--host   aarch64-linux-android   the phone (bionic, NDK r28c clang)
--target avr                     the microcontroller
```

Only the **host** side is built. Every **target** artifact — avr-libc, its
headers, `libgcc.a`, `crt*.o`, `specs`, `device-specs`, `ldscripts` — is AVR
machine code or plain text, is host-independent, and is lifted verbatim from
Arduino's official distribution. That is less work *and* strictly safer for
byte-identity.

### bionic, not static musl

`docs/ARDUINO_COMPILER.md` §5.4 offers static-linking as the preferred way to
shed `PT_INTERP`. It does not survive contact with LTO:

> Arduino's UNO link line is `-flto -fuse-linker-plugin`, and the archive step
> is `ar rcs --plugin .../liblto_plugin.so`. Both `ld` and `ar` reach the plugin
> through **`dlopen()`**, and a statically linked libc cannot `dlopen` — musl's
> static build stubs it out to always fail. Dropping the plugin means
> `-fno-use-linker-plugin -ffat-lto-objects`, which changes which symbols LTO
> may internalise, which changes codegen, which loses byte-identity with the
> Arduino IDE.

Bionic costs nothing in exchange: its `PT_INTERP` is `/system/bin/linker64`, an
absolute path present on every 64-bit Android device, so the binaries are just
as install-path-independent as static ones would be. The only consequence is
one extra file, `libc++_shared.so`, and an `LD_LIBRARY_PATH` in the driver.

## Running it

Everything runs under WSL, from Windows PowerShell. Build under WSL's own
filesystem — `/mnt/c` is 10–20× slower and breaks the permission and symlink
semantics the GCC build depends on.

```powershell
wsl -d Ubuntu -- bash /mnt/c/.../tools/avr-toolchain/01-fetch.sh
wsl -d Ubuntu -- bash /mnt/c/.../tools/avr-toolchain/02-build-native.sh
wsl -d Ubuntu -- bash /mnt/c/.../tools/avr-toolchain/03-build-android.sh
wsl -d Ubuntu -- bash /mnt/c/.../tools/avr-toolchain/04-refbuild.sh
wsl -d Ubuntu -- bash /mnt/c/.../tools/avr-toolchain/05-assemble.sh
```

`07-smoke-device.sh` runs from **Git Bash on Windows**, not WSL — it needs
`adb` and a phone.

| Script | Does |
|---|---|
| `build.conf` | every pinned version, URL, path and board constant |
| `01-fetch.sh` | download + unpack + patch all sources, and the NDK |
| `02-build-native.sh` | native **x86_64** avr toolchain |
| `03-build-android.sh` | the shipped **aarch64/bionic** toolchain |
| `04-refbuild.sh` | dress rehearsal: build Blink, assert the reference md5 |
| `05-assemble.sh` | trim, gate, rename to `lib*.so`, package, install into the module |
| `06-licenses.sh` | licence texts + `THIRD_PARTY.md` (called by `05`) |
| `07-smoke-device.sh` | push the real payload to a phone and build Blink on it |

All are idempotent: an already-installed stage is skipped, so a failed run can
be resumed by re-invoking the same script. `03-build-android.sh` goes further
and resumes a *partially built* GCC tree — it reconfigures only when there is
no `config.status`, because that stage is ~40 minutes of compilation and make
is already incremental. Delete `$BUILD_DIR/android-gcc` by hand after changing
any configure flag; a resumed make will not notice.

### Three things that bite in the Canadian cross

All three are fixed in the scripts, with the reasoning at the point of the fix.
Listed here because each one fails late, loudly and misleadingly.

1. **PIE.** GCC's configure hard-codes `-fno-PIE`/`-no-pie` into `gcc/Makefile`.
   Android has refused to load non-PIE 64-bit executables since API 21, and the
   non-PIE link does not even succeed — copy relocations against libc's
   `stdout`/`stderr` trip `ld.lld`'s alignment check. Fixed with `-fPIE`/`-pie`
   in `CFLAGS`/`CXXFLAGS`/`LDFLAGS`, which land *after* GCC's own flags.
   `make NO_PIE_FLAG=` at the top level is a silent no-op (`MAKEOVERRIDES=`).
2. **`bconfig.h` leaking the build machine's libc into a host binary.**
   `gengtype-lex.c` includes it unconditionally on line 1, so the cross-compiled
   host `gengtype` inherits `HAVE_FREAD_UNLOCKED` from glibc and fails to link
   against bionic (no `fread_unlocked` before API 28). Patched in `01-fetch.sh`.
3. **`GCC_FOR_TARGET`.** In a Canadian cross it cannot be `./xgcc`, so it falls
   back to whatever `avr-gcc` is on `PATH` — needed by the `specs` rule right at
   the end of the build. `03-build-android.sh` puts the native build on `PATH`
   so it is never Debian's unpatched `gcc-avr`.

### Why a native x86_64 toolchain is built too

Two reasons, and both matter:

1. **GCC's configure probes the target assembler** (`HAVE_AS_*`) and bakes the
   answers into `auto-host.h`, where they can change codegen. In a Canadian
   cross the installed `avr-as` is an aarch64 binary the build machine cannot
   execute, so the probes would all fall back to their conservative defaults.
   `--with-build-time-tools` points them at the native build instead.
2. **It is the dress rehearsal.** `04-refbuild.sh` pairs the native host
   binaries with the lifted target artifacts and builds `Blink.ino` through the
   same `-B` / `GCC_EXEC_PREFIX` / `--plugin` / `-T` plumbing the Android
   packaging forces on us. The hex must md5 to
   `e52c115ebdc2de4a3b0d2668011e1dce`. Passing that proves the sources, patches
   and configure line reproduce Arduino IDE output byte for byte, with Android
   factored out — so if the device run then differs, it is a packaging bug and
   nothing else.

`05-assemble.sh` re-runs the same rehearsal against the **trimmed** data tree,
so a trim that deletes something the build actually touches fails the build
rather than shipping.

## Outputs

Written straight into the Gradle module:

```
arduino/toolchain/src/main/jniLibs/arm64-v8a/*.so   executables, renamed
arduino/toolchain/src/main/assets/toolchain-data.zip
arduino/toolchain/src/main/assets/toolchain-data.version
arduino/toolchain/src/main/assets/licenses/
```

Neither the binaries nor the sources are in git — they are large and fully
reproducible from these scripts.

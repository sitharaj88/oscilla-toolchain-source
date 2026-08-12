# tools/avr-toolchain/ship/ — app-context exec proof

Complements the main pipeline (`../01-fetch` → `../02-build-native` →
`../03-build-android` → `../04-refbuild` → `../05-assemble` → `../07-smoke-device`).

Packaging is owned by `../05-assemble.sh`. This directory does **not** package —
it answers the one question nothing else does: **do the rebuilt bionic binaries
actually `execve()` from inside a real app?**

`../07-smoke-device.sh` deliberately does not test that (it runs under `adb
shell`, and memo §5.1 is explicit that `adb shell`/`run-as` gives the wrong
answer). The spike proved exec rules only with a toy glibc probe. These scripts
prove it with the genuine rebuilt toolchain, from a release-manifest APK.

## Result — PROVEN on moto g86 (ZA2237J9DZ), Android 16 / SDK 36

Release manifest (no `android:debuggable`), `adb install --no-incremental`,
launched normally:

```
selinux_context = u:r:untrusted_app:s0:c193,c258,c512,c768
targetSdk       = 35
nativeLibraryDir= /data/app/~~tBRSUqBravfEXqpL6dfOsA==/com.oscilla.tcexec-.../lib/arm64
listing         = [libavras.so, libavrld.so, libc++_shared.so]

RESULT A libavrld.so --version  => EXEC_OK rc=0  GNU ld (GNU Binutils) 2.26.20160125
RESULT C libavras.so --version  => EXEC_OK rc=0  GNU assembler (GNU Binutils) 2.26.20160125
RESULT D filesDir/avr-ld(symlink)->libavrld.so => EXEC_OK rc=0  GNU ld ...
```

Row **D** is the load-bearing one: a bare-named symlink in `filesDir`
(`app_data_file`) resolving to the real `lib*.so` in `nativeLibraryDir` execs
fine, so GCC can keep exec'ing children by bare name (`as`, `ld`, `cc1plus`)
over a read-only, `lib*.so`-only directory — the production symlink farm.

## Scripts
- `stage-prelibs.sh` — copy already-built bionic binaries into `exectest/prelibs`
  and assert ET_DYN / `PT_INTERP=/system/bin/linker64` / `p_align>=0x4000`.
- `exectest/ExecTestTC.java` + `AndroidManifest.xml` + `build-apk-tc.sh` — the
  release-shaped APK. `JNILIBS` and `LIBS` are overridable to prove a subset.
- `80-exectest.sh` — install, launch, capture the `OSCILLA_TCEXEC` transcript.
- `watch-cc1plus.sh` / `watch-android.sh` — read-only waiters on the build.
- `check-refbuild.sh` — report the byte-identity md5.
- `31-finish-gcc.sh` — recovery path for a tree configured before the PIE fix.
- `diag-pie.sh` — the diagnostic behind the PIE finding below.

## The PIE finding (why the first GCC build failed)

`make all-host` died linking `gcov`, `gcov-tool` and `xgcc` with

```
ld.lld: error: gcov.o:(function main: .text+0x2058): improper alignment for
relocation R_AARCH64_LDST64_ABS_LO12_NC: 0x287844 is not aligned to 8 bytes
```

It was never a gcov quirk. GCC's configure sees that clang accepts `-no-pie`
and emits `NO_PIE_FLAG = -no-pie` with `LINKER += $(NO_PIE_FLAG)`, so every
compiler binary links **non-PIE**. On Android that is fatal twice:

1. A non-PIE link makes lld emit **copy relocations** for libc data into `.bss`.
   Dumping gcc.o's relocations shows the misaligned targets are `stdout` (52
   refs), `stderr` (29) and a pile of `.bss+0xNN` — the copy-reloc'd globals.
   bionic's copies land 4-byte aligned, so 64-bit loads against them fail
   lld's alignment check.
2. Android's loader has refused to exec non-PIE (ET_EXEC) binaries since API 21,
   so a non-PIE toolchain is unshippable regardless.

Fix (now in `../03-build-android.sh`): `-fPIE` in `CFLAGS`/`CXXFLAGS` and `-pie`
in `LDFLAGS`, which land after `LINKER`'s `-no-pie` and win on last-flag-wins.
Note a top-level `make NO_PIE_FLAG=` is a silent no-op — GCC sets
`MAKEOVERRIDES=`, so command-line variables never reach the sub-makes.

Corollary for `31-finish-gcc.sh`: running make inside `gcc/` makes
`NO_PIE_FLAG=` work, but loses the top-level's `CC_FOR_BUILD=gcc`, so build-side
generators get cross-compiled and die on bionic's missing `fflush_unlocked`.
That script therefore restates `CC_FOR_BUILD`/`CXX_FOR_BUILD`.

# Corresponding source for the AVR toolchain shipped in Oscilla

Author: Sitharaj Seenivasan

Oscilla (Android package `com.sitharaj88.oscilla`) bundles a build of the GNU AVR
toolchain — `avr-gcc` and GNU binutils — and runs it on the device to compile Arduino
sketches. Those programs are licensed under the **GNU General Public License, version 3
or later**, and GPLv3 §6 requires that anyone who receives the binaries can also obtain
the source they were built from.

This repository is that offer. It contains the complete recipe used to produce the
binaries in the shipped app: the pinned upstream versions, every patch
applied, and the scripts that fetch, configure, build, trim and package them.

## What is here

| Path | What it is |
|---|---|
| `build.conf` | The pinned upstream component versions and download URLs |
| `00-prereqs.sh`, `00-check-env.sh` | Build-host prerequisites and environment checks |
| `01-fetch.sh` | Downloads the upstream tarballs and applies the patches |
| `02-build-native.sh` | Builds the host (x86-64 Linux) toolchain used as the reference |
| `03-build-android.sh` | Cross-builds the aarch64 Android toolchain that ships in the app |
| `04-refbuild.sh` | Byte-identity check against the reference build |
| `05-assemble.sh` | Trims and packages the payload for the APK |
| `06-licenses.sh` | Collects the upstream licence texts |
| `07-smoke-device.sh` | On-device smoke test |
| `ship/` | Diagnostic and recovery helpers used during bring-up |

The upstream sources themselves are **not** mirrored here. `01-fetch.sh` downloads them
from their original locations, pinned by exact version in `build.conf`, so a rebuild uses
the same released tarballs the shipped binaries were built from.

**Known gap, stated plainly:** `build.conf` pins versions and URLs but does not currently
record a checksum for each downloaded tarball. Integrity is instead demonstrated at the
other end — `04-refbuild.sh` verifies that a rebuild reproduces the reference image byte
for byte (see below). Recording per-tarball checksums is a planned hardening step.

## Rebuilding

On an x86-64 Linux host (a WSL2 Ubuntu installation is fine):

```sh
./00-prereqs.sh        # install build dependencies
./01-fetch.sh          # download + patch upstream sources
./02-build-native.sh   # host toolchain (reference)
./03-build-android.sh  # aarch64 Android toolchain (what ships)
./04-refbuild.sh       # verify
./05-assemble.sh       # package
```

## Verifying a rebuild matches

`04-refbuild.sh` compiles the standard Arduino `Blink` sketch and compares the result
against the reference build. A correct rebuild produces a 2,615-byte Intel HEX file with
MD5 `e52c115ebdc2de4a3b0d2668011e1dce`, which is also byte-identical to the output of the
Arduino IDE for the same sketch and board.

## Components and licences

| Component | Licence |
|---|---|
| GCC (`avr-gcc`) | GPL-3.0-or-later |
| GNU binutils | GPL-3.0-or-later |
| avr-libc | BSD-3-Clause |
| Arduino AVR core | LGPL-2.1 |

The GPL programs are executed by Oscilla as separate processes. Oscilla's own source is a
separate work and is not covered by their licences.

## Written offer

For three years from the distribution of any Oscilla release containing these binaries,
the corresponding source can be obtained from this repository:

<https://github.com/sitharaj88/oscilla-toolchain-source>

If that location is ever unavailable, contact the author via <https://sitharaj.in>.

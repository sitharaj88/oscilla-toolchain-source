#!/bin/bash
# Verify WSL environment, build tools, and the reusable AVR target libs.
set -e
echo "=== uname ==="
uname -a
echo "=== nproc ==="
nproc
echo "=== disk free ==="
df -h / | tail -1
echo "=== build tools ==="
for t in gcc g++ make wget xz bzip2 python3 flex bison makeinfo gawk tar; do
  printf "%-10s " "$t"
  command -v "$t" || echo "MISSING"
done
echo "=== avr target libs (reuse verbatim) ==="
ls -la ~/avrspike/tc/avr 2>/dev/null && echo "FOUND avrspike/tc/avr" || echo "MISSING ~/avrspike/tc/avr"
echo "=== avr toolchain tree top ==="
ls -la ~/avrspike/tc 2>/dev/null || echo "no ~/avrspike/tc"
echo "=== path conv check ==="
ls /mnt/c/Users/ASUS/Documents/electronic_simulator/tools/avr-toolchain/ | head

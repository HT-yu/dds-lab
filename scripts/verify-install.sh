#!/usr/bin/env bash
# Verify that all three middleware stacks are installed and runnable.
set -uo pipefail

source /usr/local/bin/ddslab/env.sh

fail=0
ok()  { printf '[ok]   %s\n' "$*"; }
bad() { printf '[FAIL] %s\n' "$*"; fail=1; }

check_file() {
    if [[ -e "$1" ]]; then ok "$1"; else bad "missing $1"; fi
}

check_cmd() {
    if command -v "$1" >/dev/null 2>&1; then
        ok "$1 -> $(command -v "$1")"
    else
        bad "command not found: $1"
    fi
}

echo "=== environment ==="
echo "DDS_PREFIX        = ${DDS_PREFIX}"
echo "BUILD_ROOT        = ${BUILD_ROOT}"
echo "LD_LIBRARY_PATH   = ${LD_LIBRARY_PATH}"
echo "CMAKE_PREFIX_PATH = ${CMAKE_PREFIX_PATH}"
echo "/dev/shm size     = $(df -h /dev/shm | awk 'NR==2 {print $2}')"

echo
echo "=== tools ==="
check_cmd iox-roudi
check_cmd iox-cpp-publisher
check_cmd iox-cpp-subscriber
check_cmd fastdds
check_cmd ddsperf
check_cmd idlc

echo
echo "=== libraries ==="
check_file "${ICEORYX_PREFIX}/lib/libiceoryx_posh.so"
check_file "${ICEORYX_PREFIX}/lib/libiceoryx_binding_c.so"
check_file "${FASTCDR_PREFIX}/lib/libfastcdr.so"
check_file "${FASTDDS_PREFIX}/lib/libfastdds.so"
check_file "${CYCLONEDDS_PREFIX}/lib/libddsc.so"
check_file "${CYCLONEDDS_PREFIX}/lib/libpsmx_iox.so"

echo
echo "=== CMake package configs ==="
while IFS= read -r f; do
    echo "  $f"
done < <(find /opt/dds -path '*/lib/cmake/*' -name '*[Cc]onfig.cmake' 2>/dev/null | sort)

echo
echo "=== example binaries ==="
find "${FASTDDS_PREFIX}" "${CYCLONEDDS_PREFIX}" -maxdepth 6 -type f -executable \
    \( -iname '*hello*' -o -iname '*ddsperf*' -o -iname '*publisher*' -o -iname '*subscriber*' \) \
    2>/dev/null | sort | head -40

echo
if [[ "$fail" == "0" ]]; then
    echo "=== verify-install: PASS ==="
else
    echo "=== verify-install: FAIL ==="
fi
exit "$fail"

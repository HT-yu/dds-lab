#!/usr/bin/env bash
# Show the container's /dev/shm usage and active shared-memory segments.
set -uo pipefail

source /usr/local/bin/ddslab/env.sh

echo "=== /dev/shm capacity ==="
df -h /dev/shm

echo
echo "=== shared-memory objects ==="
if compgen -G '/dev/shm/*' >/dev/null; then
    ls -lh /dev/shm | sed -n '1,60p'
else
    echo "(empty)"
fi

echo
echo "=== segment counts ==="
printf 'iceoryx/iox : %s\n' "$(find /dev/shm -maxdepth 1 -iname '*iceoryx*' -o -maxdepth 1 -iname '*iox*' 2>/dev/null | wc -l)"
printf 'fastdds     : %s\n' "$(find /dev/shm -maxdepth 1 \( -iname '*fastdds*' -o -iname '*fastrtps*' \) 2>/dev/null | wc -l)"

echo
echo "=== processes ==="
pgrep -a iox-roudi 2>/dev/null || echo "iox-roudi not running"

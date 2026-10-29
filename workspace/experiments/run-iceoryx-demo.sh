#!/usr/bin/env bash
# iceoryx: RouDi + C++ publisher/subscriber (zero-copy shared memory).
set -uo pipefail

source /usr/local/bin/ddslab/env.sh

LOG_ROOT="${LOG_ROOT:-/workspace/logs}"
LOG_DIR="${LOG_ROOT}/iceoryx-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOG_DIR"

PUBLISHER="$(command -v iox-cpp-publisher || true)"
SUBSCRIBER="$(command -v iox-cpp-subscriber || true)"
ROUDI="$(command -v iox-roudi || true)"
if [[ -z "$PUBLISHER" || -z "$SUBSCRIBER" || -z "$ROUDI" ]]; then
    echo "[FAIL] iceoryx example binaries not found"
    exit 1
fi

ROUDI_PID=""
cleanup() {
    [[ -n "${SUB_PID:-}" ]] && kill "$SUB_PID" 2>/dev/null
    [[ -n "${PUB_PID:-}" ]] && kill "$PUB_PID" 2>/dev/null
    if [[ -n "$ROUDI_PID" ]]; then
        kill "$ROUDI_PID" 2>/dev/null
        wait "$ROUDI_PID" 2>/dev/null
    fi
}
trap cleanup EXIT

if pgrep -x iox-roudi >/dev/null; then
    echo "[info] reusing running iox-roudi"
else
    "$ROUDI" >"${LOG_DIR}/roudi.log" 2>&1 &
    ROUDI_PID=$!
    for _ in $(seq 1 30); do
        pgrep -x iox-roudi >/dev/null && break
        sleep 0.2
    done
    sleep 1
    if ! pgrep -x iox-roudi >/dev/null; then
        echo "[FAIL] iox-roudi did not start"
        cat "${LOG_DIR}/roudi.log"
        exit 1
    fi
fi

"$SUBSCRIBER" >"${LOG_DIR}/subscriber.log" 2>&1 &
SUB_PID=$!
sleep 1
"$PUBLISHER" >"${LOG_DIR}/publisher.log" 2>&1 &
PUB_PID=$!

sleep 3
grep -h '/dev/shm' "/proc/${PUB_PID}/maps" >"${LOG_DIR}/publisher-shm-maps.txt" 2>/dev/null || true
ls -lh /dev/shm >"${LOG_DIR}/shm.txt" 2>&1 || true
sleep 3

# The iceoryx C++ example prints "iox-cpp-subscriber got value: N".
RECEIVED="$(grep -ci 'got value' "${LOG_DIR}/subscriber.log" || true)"
echo "=== iceoryx demo logs: ${LOG_DIR} ==="
echo "--- publisher ---"; tail -8 "${LOG_DIR}/publisher.log"
echo "--- subscriber ---"; tail -8 "${LOG_DIR}/subscriber.log"
echo "--- shared-memory mappings ---"; sed -n '1,5p' "${LOG_DIR}/publisher-shm-maps.txt"
echo "--- /dev/shm ---"; sed -n '1,15p' "${LOG_DIR}/shm.txt"

if [[ "${RECEIVED:-0}" -gt 0 ]]; then
    echo "[PASS] iceoryx pub/sub over shared memory (${RECEIVED} samples)"
    exit 0
fi
echo "[FAIL] subscriber received no samples"
exit 1

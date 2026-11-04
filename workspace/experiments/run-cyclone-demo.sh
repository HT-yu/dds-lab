#!/usr/bin/env bash
# Cyclone DDS: ddsperf pub/sub.
#
# Usage: run-cyclone-demo.sh [udp|shm]
#   udp  - default Cyclone DDS UDP path
#   shm  - iceoryx shared-memory path (starts iox-roudi, uses cyclonedds-shm.xml)
set -uo pipefail

source /usr/local/bin/ddslab/env.sh

MODE="${1:-udp}"
LOG_ROOT="${LOG_ROOT:-/workspace/logs}"
LOG_DIR="${LOG_ROOT}/cyclone-${MODE}-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOG_DIR"

if ! command -v ddsperf >/dev/null 2>&1; then
    echo "[FAIL] ddsperf not found (was BUILD_EXAMPLES=ON?)"
    exit 1
fi

ROUDI_PID=""
cleanup() {
    [[ -n "${SUB_PID:-}" ]] && kill "$SUB_PID" 2>/dev/null
    [[ -n "$ROUDI_PID" ]] && kill "$ROUDI_PID" 2>/dev/null
    [[ -n "$ROUDI_PID" ]] && wait "$ROUDI_PID" 2>/dev/null
}
trap cleanup EXIT

if [[ "$MODE" == "shm" ]]; then
    if [[ ! -f "$DDSLAB_CYCLONE_SHM_CONFIG" ]]; then
        echo "[FAIL] missing config: ${DDSLAB_CYCLONE_SHM_CONFIG}"
        exit 1
    fi
    if pgrep -x iox-roudi >/dev/null; then
        echo "[info] reusing running iox-roudi"
    else
        iox-roudi >"${LOG_DIR}/roudi.log" 2>&1 &
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
    export CYCLONEDDS_URI="file://${DDSLAB_CYCLONE_SHM_CONFIG}"
else
    unset CYCLONEDDS_URI
fi

echo "[info] CYCLONEDDS_URI=${CYCLONEDDS_URI:-<unset>}"

ddsperf -D 12 sub >"${LOG_DIR}/subscriber.log" 2>&1 &
SUB_PID=$!
sleep 2
ddsperf -D 5 pub >"${LOG_DIR}/publisher.log" 2>&1 || true
sleep 1

# The subscriber is still alive here (12 s vs. 2 + 5 + 1 s), so /proc works.
if [[ "$MODE" == "shm" ]]; then
    grep -h '/dev/shm' "/proc/${SUB_PID}/maps" >"${LOG_DIR}/subscriber-shm-maps.txt" 2>/dev/null || true
    ls -lh /dev/shm >"${LOG_DIR}/shm.txt" 2>&1 || true
fi

wait "$SUB_PID" 2>/dev/null || true

echo "=== Cyclone DDS (${MODE}) logs: ${LOG_DIR} ==="
echo "--- publisher ---"; tail -20 "${LOG_DIR}/publisher.log"
echo "--- subscriber ---"; tail -20 "${LOG_DIR}/subscriber.log"
if [[ "$MODE" == "shm" ]]; then
    echo "--- shared-memory mappings ---"; sed -n '1,10p' "${LOG_DIR}/subscriber-shm-maps.txt"
    echo "--- /dev/shm ---"; sed -n '1,15p' "${LOG_DIR}/shm.txt"
fi

psmx_active=0
if grep -q 'Loading PSMX instance' "${LOG_DIR}/subscriber.log" 2>/dev/null; then
    psmx_active=1
fi
if [[ -s "${LOG_DIR}/subscriber-shm-maps.txt" ]]; then
    psmx_active=1
fi

if ! grep -Eiq 'received|samples|size' "${LOG_DIR}/subscriber.log"; then
    echo "[FAIL] Cyclone DDS (${MODE}) subscriber produced no statistics"
    exit 1
fi
if grep -Eiq 'error loading PSMX|failed to initialize PSMX|No such file' "${LOG_DIR}/subscriber.log"; then
    echo "[FAIL] Cyclone DDS PSMX initialization failed"
    exit 1
fi
if [[ "$MODE" == "shm" && "$psmx_active" != "1" ]]; then
    echo "[FAIL] Cyclone DDS ran, but no PSMX/iceoryx activity was detected"
    exit 1
fi

echo "[PASS] Cyclone DDS (${MODE}) pub/sub"
exit 0

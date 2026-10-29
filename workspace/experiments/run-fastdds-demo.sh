#!/usr/bin/env bash
# Fast DDS: hello_world pub/sub using the built-in shared-memory transport.
set -uo pipefail

source /usr/local/bin/ddslab/env.sh

LOG_ROOT="${LOG_ROOT:-/workspace/logs}"
LOG_DIR="${LOG_ROOT}/fastdds-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOG_DIR"

# Fast DDS 3.x builds a single binary with publisher/subscriber subcommands,
# installed under share/fastdds/examples/cpp/hello_world/bin/.
HELLO_WORLD="$(find "$FASTDDS_PREFIX" -type f -executable -name hello_world 2>/dev/null | head -1)"
if [[ -z "$HELLO_WORLD" ]]; then
    echo "[FAIL] Fast DDS hello_world example not found under ${FASTDDS_PREFIX}"
    echo "Available example binaries:"
    find "$FASTDDS_PREFIX" -type f -executable 2>/dev/null | head -40
    exit 1
fi

cleanup() {
    [[ -n "${PUB_PID:-}" ]] && kill "$PUB_PID" 2>/dev/null
    [[ -n "${SUB_PID:-}" ]] && kill "$SUB_PID" 2>/dev/null
}
trap cleanup EXIT

# hello_world publishes every 100 ms and exits after --samples. Use enough
# samples that both processes are still alive when we snapshot /proc.
"$HELLO_WORLD" subscriber --samples 100 >"${LOG_DIR}/subscriber.log" 2>&1 &
SUB_PID=$!
sleep 1
"$HELLO_WORLD" publisher --samples 100 >"${LOG_DIR}/publisher.log" 2>&1 &
PUB_PID=$!

sleep 1
grep -h '/dev/shm' "/proc/${PUB_PID}/maps" >"${LOG_DIR}/publisher-shm-maps.txt" 2>/dev/null || true
ls -lh /dev/shm >"${LOG_DIR}/shm.txt" 2>&1 || true

# Wait for both sides, but never hang the smoke test.
for _ in $(seq 1 30); do
    kill -0 "$PUB_PID" 2>/dev/null || kill -0 "$SUB_PID" 2>/dev/null || break
    sleep 1
done

echo "=== Fast DDS demo logs: ${LOG_DIR} ==="
echo "--- publisher ---"; tail -15 "${LOG_DIR}/publisher.log"
echo "--- subscriber ---"; tail -15 "${LOG_DIR}/subscriber.log"
echo "--- shared-memory mappings ---"; sed -n '1,10p' "${LOG_DIR}/publisher-shm-maps.txt"
echo "--- /dev/shm ---"; sed -n '1,15p' "${LOG_DIR}/shm.txt"

if grep -Eiq 'Hello world.*RECEIVED' "${LOG_DIR}/subscriber.log"; then
    if [[ -s "${LOG_DIR}/publisher-shm-maps.txt" ]]; then
        echo "[PASS] Fast DDS hello_world over shared memory"
    else
        echo "[WARN] Fast DDS pub/sub worked, but no /dev/shm mapping was observed"
        echo "[PASS] Fast DDS hello_world (transport unverified)"
    fi
    exit 0
fi
echo "[FAIL] no HelloWorld traffic observed on the subscriber"
exit 1

#!/usr/bin/env bash
# Run every smoke test and print a summary.
set -uo pipefail

source /usr/local/bin/ddslab/env.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_ROOT="${LOG_ROOT:-/workspace/logs}/smoke-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOG_ROOT"
export LOG_ROOT

declare -a RESULTS=()
overall=0

run_step() {
    local name="$1"; shift
    echo
    echo "########## ${name} ##########"
    local log="${LOG_ROOT}/${name}.log"
    if "$@" 2>&1 | tee "$log"; then
        RESULTS+=("PASS  ${name}  (${log})")
    else
        RESULTS+=("FAIL  ${name}  (${log})")
        overall=1
    fi
}

run_step verify-install  /usr/local/bin/ddslab/verify-install.sh
run_step iceoryx        "${SCRIPT_DIR}/run-iceoryx-demo.sh"
run_step fastdds        "${SCRIPT_DIR}/run-fastdds-demo.sh"
run_step cyclone-udp    "${SCRIPT_DIR}/run-cyclone-demo.sh" udp
run_step cyclone-shm    "${SCRIPT_DIR}/run-cyclone-demo.sh" shm

echo
echo "================ SUMMARY ================"
for line in "${RESULTS[@]}"; do echo "$line"; done
echo "Logs: ${LOG_ROOT}"
exit "$overall"

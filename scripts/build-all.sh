#!/usr/bin/env bash
# Fetch sources (if needed) and build the whole stack in dependency order.
#
# Usage:
#   build-all.sh                 # fetch if missing, build all
#   build-all.sh fastcdr fastdds # build selected components
#   DDSLAB_FETCH=always build-all.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/env.sh"

mkdir -p "$SRC_ROOT" "$BUILD_DIR"

need_fetch=0
for d in iceoryx Fast-CDR Fast-DDS cyclonedds; do
    [[ -d "${SRC_ROOT}/${d}" ]] || need_fetch=1
done

if [[ "${DDSLAB_FETCH:-auto}" == "always" ]] || [[ "$need_fetch" == "1" ]]; then
    "${SCRIPT_DIR}/fetch-sources.sh"
else
    echo "=== Sources already present in ${SRC_ROOT} (DDSLAB_FETCH=always to re-fetch) ==="
fi

if [[ $# -eq 0 ]]; then
    set -- fastcdr iceoryx fastdds cyclonedds
fi

start_all=$SECONDS
for component in "$@"; do
    case "$component" in
        fastcdr)    script="${SCRIPT_DIR}/build-fastcdr.sh" ;;
        iceoryx)    script="${SCRIPT_DIR}/build-iceoryx.sh" ;;
        fastdds)    script="${SCRIPT_DIR}/build-fastdds.sh" ;;
        cyclonedds) script="${SCRIPT_DIR}/build-cyclonedds.sh" ;;
        *)
            echo "ERROR: unknown component '${component}'" >&2
            echo "Choose from: fastcdr iceoryx fastdds cyclonedds" >&2
            exit 2
            ;;
    esac
    component_start=$SECONDS
    "${script}"
    echo "--- ${component} built in $((SECONDS - component_start))s ---"
done

echo "=== All requested components built in $((SECONDS - start_all))s ==="

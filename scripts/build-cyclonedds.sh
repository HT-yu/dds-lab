#!/usr/bin/env bash
# Build and install Eclipse Cyclone DDS with iceoryx shared-memory support.
#
# Cyclone DDS 11 implements iceoryx as the "psmx_iox" PSMX plugin. The plugin
# is only active when the XML config declares a PubSubMessageExchange of type
# iox and iox-roudi is running. The default UDP path still works.
set -euo pipefail

source /usr/local/bin/ddslab/env.sh

SRC="${SRC_ROOT}/cyclonedds"
BUILD="${BUILD_DIR}/cyclonedds"
JOBS="${JOBS:-$(nproc)}"

if [[ ! -d "$SRC" ]]; then
    echo "ERROR: ${SRC} not found; run fetch-sources.sh first" >&2
    exit 1
fi
if [[ ! -e "${ICEORYX_PREFIX}/lib/libiceoryx_posh.so" ]]; then
    echo "ERROR: iceoryx not installed in ${ICEORYX_PREFIX}" >&2
    exit 1
fi

echo "=== Cyclone DDS -> ${CYCLONEDDS_PREFIX} (${JOBS} jobs) ==="

cmake -S "$SRC" -B "$BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE="${DDSLAB_BUILD_TYPE:-Release}" \
    -DCMAKE_INSTALL_PREFIX="$CYCLONEDDS_PREFIX" \
    -DCMAKE_PREFIX_PATH="$ICEORYX_PREFIX" \
    -DBUILD_SHARED_LIBS=ON \
    -DBUILD_EXAMPLES=ON \
    -DBUILD_TESTING=OFF \
    -DENABLE_ICEORYX=ON \
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
    -DCMAKE_C_COMPILER_LAUNCHER=ccache \
    -DCMAKE_CXX_COMPILER_LAUNCHER=ccache

cmake --build "$BUILD" --parallel "$JOBS"
cmake --install "$BUILD"

echo "=== Cyclone DDS installed ==="

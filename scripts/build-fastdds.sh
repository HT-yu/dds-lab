#!/usr/bin/env bash
# Build and install eProsima Fast DDS 3.x.
#
# Fast DDS 3.x finds the system Asio, TinyXML2, OpenSSL, SQLite, Boost and
# foonathan_memory packages. It ships its own shared-memory transport, so no
# iceoryx is needed. Fast DDS 3.6 no longer has a global THIRDPARTY option.
set -euo pipefail

source /usr/local/bin/ddslab/env.sh

SRC="${SRC_ROOT}/Fast-DDS"
BUILD="${BUILD_DIR}/Fast-DDS"
JOBS="${JOBS:-$(nproc)}"

if [[ ! -d "$SRC" ]]; then
    echo "ERROR: ${SRC} not found; run fetch-sources.sh first" >&2
    exit 1
fi
if [[ ! -f "${FASTCDR_PREFIX}/lib/cmake/fastcdr/fastcdr-config.cmake" ]]; then
    echo "ERROR: Fast-CDR not installed in ${FASTCDR_PREFIX}" >&2
    exit 1
fi

echo "=== Fast DDS -> ${FASTDDS_PREFIX} (${JOBS} jobs) ==="

cmake -S "$SRC" -B "$BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE="${DDSLAB_BUILD_TYPE:-Release}" \
    -DCMAKE_INSTALL_PREFIX="$FASTDDS_PREFIX" \
    -DCMAKE_PREFIX_PATH="$FASTCDR_PREFIX" \
    -DBUILD_SHARED_LIBS=ON \
    -DBUILD_TESTING=OFF \
    -DCOMPILE_EXAMPLES=ON \
    -DINSTALL_EXAMPLES=ON \
    -DCOMPILE_TOOLS=ON \
    -DINSTALL_TOOLS=ON \
    -DSHM_TRANSPORT_DEFAULT=ON \
    -DFASTDDS_STATISTICS=ON \
    -DSQLITE3_SUPPORT=ON \
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
    -DCMAKE_C_COMPILER_LAUNCHER=ccache \
    -DCMAKE_CXX_COMPILER_LAUNCHER=ccache

cmake --build "$BUILD" --parallel "$JOBS"
cmake --install "$BUILD"

echo "=== Fast DDS installed ==="

#!/usr/bin/env bash
# Build and install Fast-CDR (dependency of Fast DDS).
set -euo pipefail

source /usr/local/bin/ddslab/env.sh

SRC="${SRC_ROOT}/Fast-CDR"
BUILD="${BUILD_DIR}/Fast-CDR"
JOBS="${JOBS:-$(nproc)}"

if [[ ! -d "$SRC" ]]; then
    echo "ERROR: ${SRC} not found; run fetch-sources.sh first" >&2
    exit 1
fi

echo "=== Fast-CDR -> ${FASTCDR_PREFIX} (${JOBS} jobs) ==="

cmake -S "$SRC" -B "$BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE="${DDSLAB_BUILD_TYPE:-Release}" \
    -DCMAKE_INSTALL_PREFIX="$FASTCDR_PREFIX" \
    -DBUILD_SHARED_LIBS=ON \
    -DBUILD_TESTING=OFF \
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
    -DCMAKE_C_COMPILER_LAUNCHER=ccache \
    -DCMAKE_CXX_COMPILER_LAUNCHER=ccache

cmake --build "$BUILD" --parallel "$JOBS"
cmake --install "$BUILD"

echo "=== Fast-CDR installed ==="

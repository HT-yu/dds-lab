#!/usr/bin/env bash
# Build and install Eclipse iceoryx (RouDi daemon, POSH, C binding).
#
# Cyclone DDS links against iceoryx_posh/hoofs when ENABLE_ICEORYX=ON, so the
# C binding must be enabled here.
#
# RouDi (iox-roudi) is only built when TOML_CONFIG=ON. iceoryx's bundled
# cpptoml helper clones from github.com at configure time, which fails on
# networks where GitHub is blocked, so feed it a codeload tarball instead.
set -euo pipefail

source /usr/local/bin/ddslab/env.sh

SRC="${SRC_ROOT}/iceoryx/iceoryx_meta"
BUILD="${BUILD_DIR}/iceoryx"
JOBS="${JOBS:-$(nproc)}"
CPPTOML_VERSION="v0.1.1"
CPPTOML_TARBALL="${DOWNLOAD_ROOT}/cpptoml-${CPPTOML_VERSION#v}.tar.gz"
CPPTOML_TEMPLATE="${SRC_ROOT}/iceoryx/iceoryx_posh/cmake/cpptoml/cpptoml.cmake.in"

if [[ ! -d "$SRC" ]]; then
    echo "ERROR: ${SRC} not found; run fetch-sources.sh first" >&2
    exit 1
fi

if [[ ! -s "$CPPTOML_TARBALL" ]]; then
    URL="https://codeload.github.com/skystrife/cpptoml/tar.gz/refs/tags/${CPPTOML_VERSION}"
    echo "=== downloading cpptoml ${CPPTOML_VERSION} ==="
    if ! curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 300 \
            -o "${CPPTOML_TARBALL}.part" "$URL"; then
        curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 300 \
            -o "${CPPTOML_TARBALL}.part" "https://ghproxy.net/${URL}"
    fi
    mv "${CPPTOML_TARBALL}.part" "$CPPTOML_TARBALL"
fi

# Replace ExternalProject's git clone with the local tarball. This is
# idempotent: the marker only appears after the first patch.
if ! grep -q DDSLAB_CPPTOML_URL "$CPPTOML_TEMPLATE"; then
    python3 - "$CPPTOML_TEMPLATE" <<'PY'
import re
import sys

path = sys.argv[1]
text = open(path).read()
replacement = '''ExternalProject_Add(ext_cpptoml
  URL               @DDSLAB_CPPTOML_URL@
  SOURCE_DIR        "${CMAKE_BINARY_DIR}/dependencies/cpptoml/src"
  BINARY_DIR        "${CMAKE_BINARY_DIR}/dependencies/cpptoml/build"
  CONFIGURE_COMMAND ""
  BUILD_COMMAND     ""
  INSTALL_COMMAND   ""
  TEST_COMMAND      ""
)'''
text, count = re.subn(r"ExternalProject_Add\(ext_cpptoml.*?\n\)", replacement, text, flags=re.S)
if count != 1:
    sys.exit("ERROR: could not patch cpptoml.cmake.in")
open(path, "w").write(text)
PY
fi

# Start the downloaded dependency from a clean state so a previously failed
# git clone does not block the tarball extraction.
rm -rf "${BUILD}/dependencies/cpptoml"

echo "=== iceoryx -> ${ICEORYX_PREFIX} (${JOBS} jobs) ==="

cmake -S "$SRC" -B "$BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE="${DDSLAB_BUILD_TYPE:-Release}" \
    -DCMAKE_INSTALL_PREFIX="$ICEORYX_PREFIX" \
    -DBUILD_SHARED_LIBS=ON \
    -DBINDING_C=ON \
    -DBUILD_TEST=OFF \
    -DEXAMPLES=ON \
    -DINTROSPECTION=ON \
    -DROUDI_ENVIRONMENT=ON \
    -DTOML_CONFIG=ON \
    -DDDSLAB_CPPTOML_URL="file://${CPPTOML_TARBALL}" \
    -DDDS_GATEWAY=OFF \
    -DCCACHE=ON \
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON

cmake --build "$BUILD" --parallel "$JOBS"
cmake --install "$BUILD"

echo "=== iceoryx installed ==="

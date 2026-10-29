#!/usr/bin/env bash
# Shared environment for the DDS lab container.
# Source this file:  source /usr/local/bin/ddslab/env.sh

if [[ "${DDSLAB_ENV_LOADED:-}" == "1" ]]; then
    return 0
fi
export DDSLAB_ENV_LOADED=1

export DDS_PREFIX="${DDS_PREFIX:-/opt/dds}"
export ICEORYX_PREFIX="${ICEORYX_PREFIX:-${DDS_PREFIX}/iceoryx}"
export FASTCDR_PREFIX="${FASTCDR_PREFIX:-${DDS_PREFIX}/fastcdr}"
export FASTDDS_PREFIX="${FASTDDS_PREFIX:-${DDS_PREFIX}/fastdds}"
export CYCLONEDDS_PREFIX="${CYCLONEDDS_PREFIX:-${DDS_PREFIX}/cyclonedds}"

export BUILD_ROOT="${BUILD_ROOT:-/build}"
export SRC_ROOT="${SRC_ROOT:-${BUILD_ROOT}/src}"
export DOWNLOAD_ROOT="${DOWNLOAD_ROOT:-${BUILD_ROOT}/downloads}"
export BUILD_DIR="${BUILD_DIR:-${BUILD_ROOT}/build}"
export CCACHE_DIR="${CCACHE_DIR:-${BUILD_ROOT}/.ccache}"

export PATH="${ICEORYX_PREFIX}/bin:${FASTDDS_PREFIX}/bin:${CYCLONEDDS_PREFIX}/bin:${PATH}"
export LD_LIBRARY_PATH="${ICEORYX_PREFIX}/lib:${FASTCDR_PREFIX}/lib:${FASTDDS_PREFIX}/lib:${CYCLONEDDS_PREFIX}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
export CMAKE_PREFIX_PATH="${ICEORYX_PREFIX}:${FASTCDR_PREFIX}:${FASTDDS_PREFIX}:${CYCLONEDDS_PREFIX}${CMAKE_PREFIX_PATH:+:${CMAKE_PREFIX_PATH}}"
export PKG_CONFIG_PATH="${ICEORYX_PREFIX}/lib/pkgconfig:${CYCLONEDDS_PREFIX}/lib/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"

# Debug/RelWithDebInfo builds are opt-in (see ADVANCED_DDS_STUDY.md). Keep the
# default Release so the smoke tests stay fast.
export DDSLAB_BUILD_TYPE="${DDSLAB_BUILD_TYPE:-Release}"

# Cyclone DDS only uses iceoryx when this XML is selected explicitly.
export DDSLAB_CYCLONE_SHM_CONFIG="${DDSLAB_CYCLONE_SHM_CONFIG:-/workspace/config/cyclonedds-shm.xml}"

# Pinned source versions. Override them on the command line if needed.
export DDSLAB_VERSION_ICEORYX="${DDSLAB_VERSION_ICEORYX:-v2.0.8}"
export DDSLAB_VERSION_FASTCDR="${DDSLAB_VERSION_FASTCDR:-v2.4.0}"
export DDSLAB_VERSION_FASTDDS="${DDSLAB_VERSION_FASTDDS:-v3.6.2}"
export DDSLAB_VERSION_CYCLONEDDS="${DDSLAB_VERSION_CYCLONEDDS:-11.0.1}"

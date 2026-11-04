#!/usr/bin/env bash
# Activate the RelWithDebInfo build of Fast DDS / Cyclone DDS.
# Build it first (inside the container), using this script so that the
# per-component prefixes are set as well:
#
#   source /usr/local/bin/ddslab/env-debug.sh
#   /usr/local/bin/ddslab/build-all.sh fastcdr fastdds cyclonedds
#
# Deleting only DDS_PREFIX is not enough: the image ENV exports
# FASTCDR_PREFIX / FASTDDS_PREFIX / CYCLONEDDS_PREFIX, and build-*.sh use
# those directly, so the debug build would land in /opt/dds.
#
# iceoryx is shared with the Release install: a Debug iceoryx is large and the
# discovery/memory experiments rarely step into RouDi itself.
#
# Back to Release:
#   unset DDS_PREFIX BUILD_DIR ICEORYX_PREFIX DDSLAB_ENV_LOADED
#   source /usr/local/bin/ddslab/env.sh

export DDSLAB_DEBUG_PREFIX="${DDSLAB_DEBUG_PREFIX:-/opt/dds-debug}"
export DDSLAB_DEBUG_BUILD_DIR="${DDSLAB_DEBUG_BUILD_DIR:-/build/build-debug}"

export DDS_PREFIX="${DDSLAB_DEBUG_PREFIX}"
export BUILD_DIR="${DDSLAB_DEBUG_BUILD_DIR}"
# The Dockerfile exports these prefixes explicitly, so they do not follow
# DDS_PREFIX on their own.
export FASTCDR_PREFIX="${DDSLAB_DEBUG_FASTCDR_PREFIX:-${DDS_PREFIX}/fastcdr}"
export FASTDDS_PREFIX="${DDSLAB_DEBUG_FASTDDS_PREFIX:-${DDS_PREFIX}/fastdds}"
export CYCLONEDDS_PREFIX="${DDSLAB_DEBUG_CYCLONEDDS_PREFIX:-${DDS_PREFIX}/cyclonedds}"
export ICEORYX_PREFIX="${ICEORYX_PREFIX:-/opt/dds/iceoryx}"
export DDSLAB_BUILD_TYPE=RelWithDebInfo

# env.sh is a no-op if it was already loaded in this shell.
unset DDSLAB_ENV_LOADED
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

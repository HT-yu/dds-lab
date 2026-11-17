#!/usr/bin/env bash
# Run this on the Windows host (Git Bash), NOT inside the container.
#
# Creates the local base image used by .env:
#   dds-lab-base:22.04
# from Canonical's ubuntu-base rootfs. No container registry is involved.
set -euo pipefail

UBUNTU_VERSION="${UBUNTU_BASE_VERSION:-22.04.5}"
ARCH="${UBUNTU_BASE_ARCH:-amd64}"
IMAGE="${BASE_IMAGE_TAG:-dds-lab-base:22.04}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_DIR="${ROOT_DIR}/.base"
ROOTFS="${BASE_DIR}/ubuntu-base-${UBUNTU_VERSION}-base-${ARCH}.tar.gz"

mkdir -p "$BASE_DIR"

if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "[skip] image ${IMAGE} already exists"
    docker image inspect "$IMAGE" --format '{{.RepoTags}} {{.Size}}'
    exit 0
fi

if [[ ! -s "$ROOTFS" ]]; then
    URL="https://mirrors.ustc.edu.cn/ubuntu-cdimage/ubuntu-base/releases/22.04/release/ubuntu-base-${UBUNTU_VERSION}-base-${ARCH}.tar.gz"
    echo "[download] ${URL}"
    curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 900 \
        -o "${ROOTFS}.part" "$URL"
    mv "${ROOTFS}.part" "$ROOTFS"
fi

echo "[import] ${ROOTFS} -> ${IMAGE}"
docker import "$ROOTFS" "$IMAGE"
docker image inspect "$IMAGE" --format '{{.RepoTags}} {{.Size}}'

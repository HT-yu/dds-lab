#!/usr/bin/env bash
# Download pinned source tarballs from codeload.github.com.
# github.com itself is not used because its DNS is not resolvable on some
# networks; codeload and ghproxy.net both work.
set -euo pipefail

source /usr/local/bin/ddslab/env.sh

mkdir -p "$SRC_ROOT" "$DOWNLOAD_ROOT" "$BUILD_DIR"

download() {
    local out="$1" primary="$2" fallback="$3"
    if [[ -s "$out" ]]; then
        echo "[skip] $(basename "$out") already downloaded"
        return 0
    fi

    echo "[download] $(basename "$out")"
    if curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 900 \
            -o "${out}.part" "$primary"; then
        :
    else
        echo "[download] primary failed; trying fallback mirror"
        curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 900 \
            -o "${out}.part" "$fallback"
    fi
    mv "${out}.part" "$out"
}

fetch_tarball() {
    local repo="$1" tag="$2" dir="$3"
    local tarball="${DOWNLOAD_ROOT}/${dir}-${tag}.tar.gz"

    download "$tarball" \
        "https://codeload.github.com/${repo}/tar.gz/refs/tags/${tag}" \
        "https://ghproxy.net/https://github.com/${repo}/archive/refs/tags/${tag}.tar.gz"

    rm -rf "${SRC_ROOT:?}/${dir}" "${SRC_ROOT:?}/${dir}.extract"
    mkdir -p "${SRC_ROOT}/${dir}.extract"
    echo "[extract] ${dir} ${tag}"
    tar -xzf "$tarball" -C "${SRC_ROOT}/${dir}.extract" --strip-components=1
    mv "${SRC_ROOT}/${dir}.extract" "${SRC_ROOT}/${dir}"
}

echo "=== Fetching sources into ${SRC_ROOT} ==="
fetch_tarball eclipse-iceoryx/iceoryx        "${DDSLAB_VERSION_ICEORYX}"   iceoryx
fetch_tarball eProsima/Fast-CDR               "${DDSLAB_VERSION_FASTCDR}"   Fast-CDR
fetch_tarball eProsima/Fast-DDS               "${DDSLAB_VERSION_FASTDDS}"   Fast-DDS
fetch_tarball eclipse-cyclonedds/cyclonedds   "${DDSLAB_VERSION_CYCLONEDDS}" cyclonedds

echo "=== Sources ready ==="
ls -la "$SRC_ROOT"

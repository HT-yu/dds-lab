# BASE_IMAGE is injected by compose/.env so the project also works on networks
# where Docker Hub is unreachable. Any Ubuntu 22.04-compatible image is fine.
ARG BASE_IMAGE=ubuntu:22.04
FROM ${BASE_IMAGE}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG DEBIAN_FRONTEND=noninteractive
ARG UBUNTU_MIRROR=mirrors.ustc.edu.cn

USER root

RUN set -eux; \
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/ubuntu.sources; do \
        if [ -f "$f" ]; then \
            sed -i \
                -e "s|http://archive.ubuntu.com/ubuntu|http://${UBUNTU_MIRROR}/ubuntu|g" \
                -e "s|http://security.ubuntu.com/ubuntu|http://${UBUNTU_MIRROR}/ubuntu|g" \
                -e "s|https://archive.ubuntu.com/ubuntu|http://${UBUNTU_MIRROR}/ubuntu|g" \
                -e "s|https://security.ubuntu.com/ubuntu|http://${UBUNTU_MIRROR}/ubuntu|g" \
                "$f"; \
        fi; \
    done; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        build-essential cmake ninja-build ccache \
        ca-certificates curl wget git \
        pkg-config bison flex \
        libssl-dev libasio-dev libtinyxml2-dev libsqlite3-dev \
        libboost-dev libboost-program-options-dev \
        libfoonathan-memory-dev \
        libacl1-dev libncurses-dev libatomic1 \
        python3 python3-pip python3-venv python3-psutil \
        iproute2 iputils-ping net-tools tcpdump iperf3 \
        tmux vim less htop procps sudo \
        gdb strace ltrace jq unzip zip tar xz-utils \
    ; \
    rm -rf /var/lib/apt/lists/*

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    DDS_PREFIX=/opt/dds \
    ICEORYX_PREFIX=/opt/dds/iceoryx \
    FASTCDR_PREFIX=/opt/dds/fastcdr \
    FASTDDS_PREFIX=/opt/dds/fastdds \
    CYCLONEDDS_PREFIX=/opt/dds/cyclonedds \
    BUILD_ROOT=/build \
    CCACHE_DIR=/build/.ccache \
    PATH=/opt/dds/iceoryx/bin:/opt/dds/fastdds/bin:/opt/dds/cyclonedds/bin:${PATH} \
    LD_LIBRARY_PATH=/opt/dds/iceoryx/lib:/opt/dds/fastcdr/lib:/opt/dds/fastdds/lib:/opt/dds/cyclonedds/lib \
    CMAKE_PREFIX_PATH=/opt/dds/iceoryx:/opt/dds/fastcdr:/opt/dds/fastdds:/opt/dds/cyclonedds

RUN mkdir -p /build/src /build/downloads /build/build /build/.ccache /opt/dds /workspace

COPY scripts/ /usr/local/bin/ddslab/
RUN chmod +x /usr/local/bin/ddslab/*.sh \
    && echo 'source /usr/local/bin/ddslab/env.sh' >> /root/.bashrc

WORKDIR /workspace
CMD ["sleep", "infinity"]

FROM ubuntu:20.04@sha256:8feb4d8ca5354def3d8fce243717141ce31e2c428701f6682bd2fafe15388214
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates curl git make python3 unzip zip xz-utils rsync file libtinfo5 libncurses5 \
    libxml2 libsqlite3-0 libcurl4 libedit2 libicu66 libatomic1 libstdc++6 zlib1g \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /workspace

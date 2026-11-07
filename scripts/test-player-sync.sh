#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
docker build -t podcold-linux:model-tests -f scripts/linux/Dockerfile.model-tests scripts/linux
docker run --rm --network none --cap-drop ALL --security-opt no-new-privileges \
    --pids-limit 128 --memory 1g --cpus 2 --user "$(id -u):$(id -g)" \
    --mount "type=bind,source=$repo_root,target=/workspace" --workdir /workspace \
    podcold-linux:model-tests /bin/bash -ec '
        .build-linux/toolchain/linux/host/bin/swiftc -module-cache-path /tmp/podcold-model-cache -parse-as-library \
            podcold/podcold/Models/PlayQueue.swift podcold/podcold/Models/Episode.swift \
            podcold/podcold/Models/Podcast.swift podcold/podcold/Models/BackupManager.swift \
            podcold/podcold/Models/PlayerSyncClient.swift \
            scripts/tests/PlayerSync.swift -o /tmp/player-sync-tests
        /tmp/player-sync-tests
    '

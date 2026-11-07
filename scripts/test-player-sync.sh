#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
.build-linux/toolchain/linux/host/bin/swiftc -use-ld=bfd -module-cache-path /tmp/podcold-model-cache -parse-as-library \
    podcold/podcold/Models/PlayQueue.swift podcold/podcold/Models/Episode.swift \
    podcold/podcold/Models/Podcast.swift podcold/podcold/Models/BackupManager.swift \
    podcold/podcold/Models/PlayerSyncClient.swift \
    scripts/tests/PlayerSync.swift -o /tmp/player-sync-tests
/tmp/player-sync-tests

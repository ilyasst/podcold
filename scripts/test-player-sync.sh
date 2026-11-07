#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
scratch_dir=$(mktemp -d)
trap 'rm -rf "$scratch_dir"' EXIT

.build-linux/toolchain/linux/host/bin/swiftc -use-ld=bfd -module-cache-path "$scratch_dir/cache" -parse-as-library \
    podcold/podcold/Models/PlayQueue.swift podcold/podcold/Models/Episode.swift \
    podcold/podcold/Models/Podcast.swift podcold/podcold/Models/BackupManager.swift \
    podcold/podcold/Models/PlayerSyncClient.swift \
    scripts/tests/PlayerSync.swift -o "$scratch_dir/player-sync-tests"
"$scratch_dir/player-sync-tests"

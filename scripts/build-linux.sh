#!/usr/bin/env bash
# Build on x86_64 Linux without installing host packages or requiring Xcode.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
for build_tool in docker curl git python3 tar sha256sum; do
    command -v "$build_tool" >/dev/null || { echo "Missing tool: $build_tool" >&2; exit 1; }
done
[[ "$(uname -m)" == x86_64 ]] || { echo 'This recipe requires an x86_64 Linux host.' >&2; exit 1; }

cache_root="$repo_root/.build-linux"
mkdir -p "$cache_root/cache" "$cache_root/toolchain"
toolchain_archive="$cache_root/cache/swift-5.6.1-ubuntu20.04.tar.xz"
toolchain_sha=7f7447fde0ca40e5854f732317aa66f5687ae200cb82ab08960b78a925fbcca4
if [[ ! -f "$toolchain_archive" ]]; then
    echo 'Downloading legacy Swift toolchain (612 MB)...'
    curl --fail --location --retry 3 --continue-at - \
        https://github.com/kabiroberai/swift-toolchain-linux/releases/download/v2.1.0/swift-5.6.1-ubuntu20.04.tar.xz \
        --output "$toolchain_archive.partial"
    mv "$toolchain_archive.partial" "$toolchain_archive"
fi
echo "$toolchain_sha  $toolchain_archive" | sha256sum --check
if [[ ! -f "$cache_root/toolchain/.complete" ]]; then
    echo 'Extracting toolchain...'
    tar --extract --xz --file "$toolchain_archive" --directory "$cache_root/toolchain"
    touch "$cache_root/toolchain/.complete"
fi

theos_revision=dd7f2f4b245930942d872421ea26e420c106fc5f
sdk_revision=0222fd5413cf4b9af096f37b4621afa2688572f7
if [[ ! -d "$cache_root/theos/.git" ]]; then
    git clone --filter=blob:none --no-checkout https://github.com/theos/theos.git "$cache_root/theos"
fi
git -C "$cache_root/theos" checkout --detach "$theos_revision"
git -C "$cache_root/theos" submodule update --init --recursive --depth 1
if [[ ! -d "$cache_root/sdks/.git" ]]; then
    git clone --depth 1 --filter=blob:none --sparse https://github.com/theos/sdks.git "$cache_root/sdks"
fi
if [[ "$(git -C "$cache_root/sdks" rev-parse HEAD)" != "$sdk_revision" ]]; then
    git -C "$cache_root/sdks" fetch --depth 1 origin "$sdk_revision"
    git -C "$cache_root/sdks" checkout --detach "$sdk_revision"
fi
git -C "$cache_root/sdks" sparse-checkout set iPhoneOS15.6.sdk
python3 scripts/linux/artifact.py prepare

docker build --tag podcold-linux:swift56 --file scripts/linux/Dockerfile scripts/linux
echo 'Compiling ARMv7 code for iOS 6 and later...'
docker run --rm --network none --cap-drop ALL --security-opt no-new-privileges \
    --pids-limit 256 --memory 4g --cpus 2 --user "$(id -u):$(id -g)" \
    --mount "type=bind,source=$repo_root,target=/workspace" \
    --workdir /workspace/.build-linux/project \
    --env THEOS=/workspace/.build-linux/theos --env PODCOLD_DEVICE_TESTING podcold-linux:swift56 make -j2
docker run --rm --network none --cap-drop ALL --security-opt no-new-privileges \
    --pids-limit 256 --memory 1g --cpus 2 --user "$(id -u):$(id -g)" \
    --mount "type=bind,source=$repo_root,target=/workspace" \
    --env PODCOLD_DEBUG \
    --env PODCOLD_DEVICE_TESTING \
    podcold-linux:swift56 python3 scripts/linux/artifact.py package

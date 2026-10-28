# Podcold fork

Fork of [RousseAddict/podcold](https://github.com/RousseAddict/podcold), a podcast player for legacy iOS devices.

## Linux ARMv7 build

The existing player can be compiled on x86_64 Linux using a pinned Theos revision, Swift 5.6.1, and the iPhoneOS 15.6 SDK. The resulting test app targets iOS 7.0 and contains ARMv7 code and the legacy Swift runtime extracted from the upstream IPA. Application sources under `podcold/` are compiled as provided.

Build and packaging have been checked on Linux. **Launch, playback, downloads, and background operation still require testing on the physical iPod.** Custom RSS entry and tappable feedback links are subsequent app changes.

Requirements: Docker, Bash, curl, Git, Python 3, tar with xz support, and sha256sum. Allow roughly 5 GB for the toolchain, SDK, Docker image, download cache, and intermediate files.

```bash
./scripts/build-linux.sh
python3 scripts/linux/artifact.py verify dist/podcold-linux-armv7.ipa
```

The first build downloads about 612 MB for the Swift toolchain, plus the SDK and container dependencies. Later builds reuse `.build-linux/` and Docker's cache. Compilation runs without networking, as the invoking user, with two CPUs and a 4 GiB memory limit. Host packages and the original Xcode build are untouched.

Outputs:

- `dist/podcold-linux-armv7.ipa`: test package, signed ad hoc with ldid.
- `dist/linux-build.json`: source/toolchain revisions, artifact hash, and structural verification results.

Install the IPA using your existing jailbroken-device installation method. It uses the distinct bundle ID `org.ilyasst.podcold.linux` and display name **Podcold Linux**, allowing it to coexist with the original app. Listening state is separate.

## Build details

- [Theos](https://github.com/theos/theos): `dd7f2f4b245930942d872421ea26e420c106fc5f` (2022 revision).
- [Linux Swift iOS toolchain](https://github.com/kabiroberai/swift-toolchain-linux/releases/tag/v2.1.0): Swift 5.6.1 for Ubuntu 20.04, checked against a pinned SHA-256.
- [Theos SDKs](https://github.com/theos/sdks): `0222fd5413cf4b9af096f37b4621afa2688572f7`, using iPhoneOS 15.6.
- Ubuntu 20.04 container base pinned by image digest.
- Existing ARMv7 curl/OpenSSL archives and the 18 Swift runtime libraries from `build/podcold_ios6.ipa`.

The Swift resource directory must explicitly select Apple's libraries; otherwise the Linux compiler imports Linux CoreFoundation/Dispatch modules. Clang needs its Darwin compiler-runtime directory for the platform-version helper used by curl. Optional SDK Swift overlays are weak-linked. The packaged executable resolves the CoreMedia Swift overlay from the bundle, matching the upstream IPA.

Icons are copied from their original PNG sources; the build does not require Apple's asset-catalog compiler. All runtime libraries are reduced to ARMv7 and re-signed. Packaging verifies ZIP integrity, bundle identity, Mach-O architecture and minimum OS for every binary, code-signature presence, required bundled dependencies, and required app symbols against the original Swift runtime export tables. These are static checks, not a substitute for a device launch or a cryptographic signature validation.

The upstream `atomic_stubs.S` currently emits a linker warning about the alignment of its `.Lno` label. The application sources are retained for this baseline build; the physical-device check remains necessary.

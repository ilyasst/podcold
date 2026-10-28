# Podcold fork

Fork of [RousseAddict/podcold](https://github.com/RousseAddict/podcold), a podcast player for legacy iOS devices.

## Linux ARMv7 build

The player can be compiled on x86_64 Linux using a pinned Theos revision, Swift 5.6.1, and the iPhoneOS 15.6 SDK. The resulting test app targets iOS 7.0 and contains ARMv7 code and the legacy Swift runtime extracted from the upstream IPA. The fork's application sources under `podcold/` are compiled directly.

Build, packaging, USB installation, launch, home-screen rendering, search-field position, keyboard focus, directory search, and adding an RSS feed by URL have been checked on an iPod touch 4 running iOS 7.1.2. The first launch exposed a missing `libarclite` dependency; linking that compatibility library allowed the app to open. The fork fixes the initially blank home screen and keeps the search field below the navigation bar. Native description links, a real 2.8 MB episode download, local playback, and 40 seconds of continued playback while Safari is in front have also passed physical-device checks. Safari loaded the public Podweaver confirmation page; no feedback was submitted.

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

## Add a feed by URL

Choose **Add Feed URL** on the empty home screen, or **Search → Add URL** at any time. Paste the RSS or Atom feed link and tap **Add Feed** (or **Go** on the keyboard). The app checks the feed, reads its title, author and artwork, saves the subscription, and opens its episode list. HTTP and HTTPS are supported; links without a scheme default to HTTPS. A podcast website or malformed feed shows an error. An existing subscription opens without creating a duplicate.

## Links in episode notes

Episode descriptions preserve tappable HTTP/HTTPS links, including Podweaver’s **More like this**, **Pass on this show**, **Undo**, and **Listened**. Tap a link to open its public page in Safari. Audio can continue while you confirm feedback, then return to Podcold. Opening a page does not submit a preference. Cached feedback links show the current preference on the public page; refreshed feed notes show updated status.

Notes use a native, read-only iOS 7 text view. Labels, paragraphs, lists, HTML entities and relative links are retained. The app does not execute description HTML or JavaScript. Non-web URL schemes are not opened. No embedded browser or new runtime dependency is added.

Episode credits also preserve item-level `itunes:author`, Dublin Core creator, and Atom episode authors. The original author appears as a byline in episode details, as the Now Playing subtitle, and as the lock-screen artist. Saved episodes retain that credit; older saved records without it continue to load. Refresh the feed to obtain newly published author metadata. Podweaver’s notes separately identify the original podcast and author for players that ignore item-level authors.

## Physical-device search test

Install `ideviceinstaller` and `libimobiledevice-utils` on the Linux host, pair the unlocked iPod, and mount Apple's signed iOS 7.1 developer image with `ideviceimagemounter`. A mounted developer image enables screenshots and launching; it is not installed by the build script.

```bash
PODCOLD_DEBUG=1 PODCOLD_DEVICE_TESTING=1 ./scripts/build-linux.sh
ideviceimagemounter mount /path/to/DeveloperDiskImage.dmg
python3 scripts/test-device.py --install
```

The test starts the app over USB, invokes its search button action, checks the actual field position and keyboard focus, then submits `audio drama` through the normal search delegate. It requires nonempty live results, so internet access is needed. It does not subscribe to a show or change listening state. Results and screenshots go into `.build-linux/device-test/`; Pillow is optional for PNG conversion. A per-run token prevents historical device logs from being mistaken for a new pass.

To test URL subscriptions instead, supply a live podcast feed:

```bash
python3 scripts/test-device.py --install --feed-url https://example.com/feed.xml
```

This scenario exercises the Add URL action, input and keyboard layout, invalid URLs, RSS/Atom metadata and validation fixtures, live episode loading, saved subscriptions, and duplicate detection. It temporarily adds the supplied feed and restores the original subscription list before reporting completion. The runner then reopens the normal home screen. Its report is `feed-results.json`; `feed-url` and `feed-added` screenshots are saved alongside it. This scenario expects the live feed to contain at least one episode, though the app can subscribe to valid empty feeds too.

To check notes and the listening flow on the physical device:

```bash
python3 scripts/test-device.py --install --notes-playback --feed-url https://example.com/podweaver/feed.xml
```

Use your real Podweaver feed with a **Listened** link and an audio episode longer than 20 seconds. This opt-in scenario checks rendering fixtures and the actual text-view links, downloads the shortest suitable episode under a temporary identity, starts local playback through the Play button, and invokes the installed link delegate to open Safari. It checks original-author display in episode details, Now Playing and lock-screen metadata, and verifies that playback advances with the app in the background for 40 seconds. It never submits the feedback form. The downloaded test file, recents, progress and queue changes are restored afterward. An interrupted check is recovered on the next launch of a device-test build; the host runner attempts that recovery before returning.

The local report is `.build-linux/device-test/notes-results.json`. `episode-notes.png` shows the native links; `notes-complete.png` captures the final Safari page. The separate feed scenario above verifies subscription entry and restores the original subscription list. See [device validation](docs/device-notes-validation.md) for the recorded scope.

`PODCOLD_DEBUG=1` signs only the test app executable with `get-task-allow` for debugging. `PODCOLD_DEVICE_TESTING=1` compiles the test runner; it runs only with the explicit `--podcold-device-test` launch argument. Both are off by default. Switching test mode invalidates cached objects. The `device_tested` field produced by static IPA verification stays false: the separate device-test report is the runtime evidence.

For stack inspection with the bundled Linux LLDB, `scripts/linux/Dockerfile.debug` adds its missing Python runtime to a separate image. This is optional; the automatic test does not need the debugger's expression evaluator.

## Build details

- [Theos](https://github.com/theos/theos): `dd7f2f4b245930942d872421ea26e420c106fc5f` (2022 revision).
- [Linux Swift iOS toolchain](https://github.com/kabiroberai/swift-toolchain-linux/releases/tag/v2.1.0): Swift 5.6.1 for Ubuntu 20.04, checked against a pinned SHA-256.
- [Theos SDKs](https://github.com/theos/sdks): `0222fd5413cf4b9af096f37b4621afa2688572f7`, using iPhoneOS 15.6.
- Ubuntu 20.04 container base pinned by image digest.
- Existing ARMv7 curl/OpenSSL archives and the 18 Swift runtime libraries from `build/podcold_ios6.ipa`.
- Apple's `libarclite_iphoneos.a` from the pinned toolchain, force-linked to supply legacy Objective-C class-registration support required by Swift on iOS 7. Xcode adds this automatically; the Linux link driver needs an explicit flag.

The Swift resource directory must explicitly select Apple's libraries; otherwise the Linux compiler imports Linux CoreFoundation/Dispatch modules. Clang needs its Darwin compiler-runtime directory for the platform-version helper used by curl. Optional SDK Swift overlays are weak-linked. The packaged executable resolves the CoreMedia Swift overlay from the bundle, matching the upstream IPA.

Icons are copied from their original PNG sources; the build does not require Apple's asset-catalog compiler. All runtime libraries are reduced to ARMv7 and re-signed. Packaging verifies ZIP integrity, bundle identity, Mach-O architecture and minimum OS for every binary, code-signature presence, required bundled dependencies, the arclite class marker and weak registration import, and required app symbols against the original Swift runtime export tables. These are static checks, not a substitute for a device launch or a cryptographic signature validation.

The upstream `atomic_stubs.S` currently emits a linker warning about the alignment of its `.Lno` label. The application sources are retained for this baseline build; the physical-device check remains necessary.

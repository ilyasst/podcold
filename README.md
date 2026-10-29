# Podcold fork

Fork of [RousseAddict/podcold](https://github.com/RousseAddict/podcold), a podcast player for legacy iOS devices.

## iOS 12 / iPod touch 6 build

The same sources also compile to a separate ARM64 IPA for iOS 12.0 and later, including the iPod touch 6. This target uses the existing Linux toolchain and the ARM64 slices of the bundled curl, OpenSSL and Swift libraries. It omits the iOS 6 allocation/atomic shims and libarclite. No player features or saved-data formats differ between the targets.

```bash
PODCOLD_ARCH=arm64 ./scripts/build-linux.sh
python3 scripts/linux/artifact.py verify dist/podcold-linux-arm64-ios12.ipa
```

Outputs are `dist/podcold-linux-arm64-ios12.ipa` and `dist/linux-arm64-build.json`. ARM64 intermediates and runtime libraries have their own directories, so this build preserves the ARMv7 IPA and its cache. Both IPAs use bundle ID `org.ilyasst.podcold.linux`, allowing an update to retain this fork's subscriptions, downloads and settings. Use the ARM64 IPA on iOS 12; the ARMv7 IPA cannot run on iOS 11 or later.

The IPA is signed ad hoc for a jailbroken device with AppSync, just like the touch 4 build. Build and static package verification have passed; installation and runtime behavior on the touch 6 are **not yet tested**. The verifier checks the ARM64 architecture and compatible deployment version of all 19 binaries, packaged runtime imports, signatures and notes delegate. Package regression tests reject wrong-architecture libraries/executables, missing runtimes and incorrect target metadata:

```bash
python3 scripts/tests/test-artifacts.py
```

Once the jailbroken touch 6 is connected, opt-in device tests can use the new IPA explicitly. Test mode is separate from the normal build:

```bash
PODCOLD_ARCH=arm64 PODCOLD_DEBUG=1 PODCOLD_DEVICE_TESTING=1 ./scripts/build-linux.sh
python3 scripts/test-device.py --device-model iPod7,1 --install \
    --ipa dist/podcold-linux-arm64-ios12.ipa --playlist
```

Mount the matching Apple developer image first. Rebuild with `PODCOLD_DEVICE_TESTING=0` afterward to generate the normal IPA without the test harness.

### Install through Sileo

Outerheaven also serves a public flat APT source at [the Podcold source](https://outerheaven.caracara-boga.ts.net:10000/podcold/). Add that URL under Sileo's Sources, then install **Podcold (iOS 12)**. Tailscale is not required on the iPod. Installation and launching on the touch 6 still need device verification.

To regenerate the package and source after building the ARM64 IPA:

```bash
python3 scripts/build-sileo-repo.py
```

The script verifies the IPA, packages its unchanged signed app into `/Applications/PodcoldLinux.app`, and generates `Packages`, gzip/bzip2 indexes and `Release` checksums under `dist/sileo/`. It uses xz compression for compatibility with older dpkg versions and root ownership for installed files. The package depends on iOS 12 or later and `uikittools`; install/remove scripts refresh only this app's icon registration. User data is not part of the package. The rootful package metadata uses `iphoneos-arm`, as required by the [Theos packaging convention](https://theos.dev/docs/packaging), while its executable and runtime libraries contain ARM64 code. This is not a rootless package.

The default package version is `1.0.0-<git commit count>`. Two older package downloads are retained for clients with cached indexes. Only the generated repository directory is published; toolchains, device backups and the rest of `dist/` are excluded. Tailscale's existing persistent Funnel serves this directory directly, without an additional app server:

```bash
sudo tailscale funnel --bg --https=10000 --set-path=/podcold \
    /home/ilyass/Repositories/podcold/dist/sileo
```

The existing `/feed.xml` proxy stays in place, and the private management interface stays private. The public source address and generated QR code are independent of podcast subscription URLs.

## Linux ARMv7 build

The player can be compiled on x86_64 Linux using a pinned Theos revision, Swift 5.6.1, and the iPhoneOS 15.6 SDK. The default build targets iOS 6.0 and contains ARMv7 code and the legacy Swift runtime extracted from the upstream IPA. ARMv7 supports compatible devices on iOS 6–10; use the ARM64 target above for iOS 12. The fork's application sources under `podcold/` are compiled directly.

Build, packaging, USB installation, launch, home-screen rendering, search-field position, keyboard focus, directory search, and adding an RSS feed by URL have been checked on an iPod touch 4 running iOS 7.1.2. The first launch exposed a missing `libarclite` dependency; linking that compatibility library allowed the app to open. The fork fixes the initially blank home screen and keeps the search field below the navigation bar. Native description links, a real 2.8 MB episode download, local playback, and 40 seconds of continued playback while Safari is in front have also passed physical-device checks. Safari loaded the public Podweaver confirmation page; no feedback was submitted.

A newly jailbroken iPod touch 4 on iOS 6.1.6 has also installed and opened the current app, and passed the playlist scenario: warm-cache Downloads reloads, options, notes, backup restoration and two local episodes playing in order. Its jailbreak uses Legacy iOS Kit's ramdisk workflow and retains iOS 6.1.6. The ad hoc package requires working AppSync on jailbroken devices.

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

Notes use a native, read-only text view on iOS 7 and later. On iOS 6, native labels show the text and native buttons open the parsed web links. Labels, paragraphs, lists, HTML entities and relative links are retained. The app does not execute description HTML or JavaScript. Non-web URL schemes are not opened. No embedded browser or new runtime dependency is added.

Episode credits also preserve item-level `itunes:author`, Dublin Core creator, and Atom episode authors. The original author appears as a byline in episode details, as the Now Playing subtitle, and as the lock-screen artist. Saved episodes retain that credit; older saved records without it continue to load. Refresh the feed to obtain newly published author metadata. Podweaver’s notes separately identify the original podcast and author for players that ignore item-level authors.

## Playlist

Tap **Playlist** at the top left of Home. This is the existing saved queue, with a dedicated screen: **Play playlist** starts its first episode and playback continues through the remaining episodes in order. It resumes an already paused episode. Tap a row for episode details, swipe to remove it, or use **Edit** to drag rows into a different order. Downloads remains accessible as a button at the top of Home.

Hold an episode in a podcast's episode list or in Downloads to **Add to playlist** or **Remove from playlist**. Episode details also has a **+ Playlist** button. Removing a playlist entry keeps its downloaded file.

Choose **Playlist → Options**, or **Settings → Automatic Episodes → Playlist Options**:

- **Add new episodes** adds new arrivals when subscribed feeds refresh.
- **Add new downloads** adds an episode when its download finishes, including manual downloads. Turn off the first switch and keep this one on for a playlist filled by downloads only.
- **Maximum episodes** sets a limit of 1–200 waiting episodes (default **50**). Lowering it preserves existing entries. Manual additions show a message when full; automatic additions wait for room in a bounded, persistent backlog of up to 200 episodes. Waiting additions refill in order as episodes leave the playlist.

Both adding rules default to **on** and apply to future arrivals. Played episodes and the episode currently playing are excluded from automatic adding. Playlist entries, order, options and waiting additions are included in backups.

The Downloads screen now applies artwork directly to the requested cell. Cached images can complete inline; asking the table to retrieve that same row from inside its data-source callback caused recursive row creation and an intermittent crash. Reused cells are checked by episode identity.

## Automatic downloads

Open **Settings → Automatic Episodes**:

- **Playlist Options** opens the automatic adding switches and the playlist size limit. New arrivals enter oldest first within each feed refresh.
- **Auto download episodes** downloads arrivals one at a time. This switch works independently of queueing.
- **Auto download limit** keeps 1–20 automatic, unplayed downloads ready across all subscriptions (default **3**). It refills as you finish episodes. Manual downloads do not consume this allowance. Lowering the limit keeps existing files; turning downloading off lets an already-started transfer finish.
- **Check feeds now** requests a fresh check immediately.

Automatic playlist adding and downloading default to **on**. A feed’s first successful check considers only its **Max new episodes** window (default 3), then remembers the identities in the fetched page. Later checks append newly seen episodes once. The window limits initial selection, rather than repeatedly walking through the back catalogue. Played/current episodes are excluded. Clearing the home-screen cache, relaunching, or removing a queued row does not re-add it. A manually deleted automatic download stays deleted.

Feed checks run on opening and at the existing 45-minute refresh interval while the app is active. This legacy build does not schedule checks while closed or suspended. Pending downloads and failed-transfer retry times persist; interrupted downloads can restart when the app returns. Failed transfers wait at least 15 minutes before retrying. No new network dependency or thread-per-episode worker is added. Manual and automatic requests for the same episode share one transfer.

The limit counts unplayed automatic files, rather than all historical files. **Delete after playing** controls whether finished files are removed. These preferences, arrival history, and pending work are included in backup/export and restore; old backups remain compatible.

## Sleep timer

On **Now Playing**, scroll below the speed control and tap **Sleep timer: Off**. Choose **15 minutes**, **30 minutes**, **60 minutes**, or **End of episode**. The button shows the remaining countdown or the end-of-episode choice. Open it again to replace the timer or choose **Turn off**; **Cancel** leaves the current setting alone.

Timed stops use elapsed time, including pauses, and keep their deadline across episode changes. They pause audio and preserve your position. The end-of-episode option finishes the current episode without consuming the next queued episode; manually choosing a different episode cancels that option. Closing the player or restarting the app clears the timer. Timers belong to the audio player and can run during background audio with the screen locked. No background polling runs when the timer is off.

## Physical-device search test

Install `ideviceinstaller` and `libimobiledevice-utils` on the Linux host, pair the unlocked iPod, and mount Apple's signed developer image matching its iOS version with `ideviceimagemounter`. A mounted developer image enables screenshots and launching; it is not installed by the build script.

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

To test the sleep timer with the same temporary download and restoration:

```bash
python3 scripts/test-device.py --install --sleep-timer --feed-url https://example.com/podweaver/feed.xml
```

This checks the native menu, all three minute presets, Cancel/Turn off, stopping at the real end of an audio file with a queued episode, queue advancement after disabling the timer, and an accelerated eight-second deadline while Safari is in front. The report is `sleep-results.json`. The short deadline checks the same timer code as the presets; it is not a full 60-minute or screen-lock endurance test. The harness holds a temporary background task to report the result after audio pauses; the normal player uses its existing background-audio mode.

To check automatic arrivals and downloads on the physical device:

```bash
python3 scripts/test-device.py --install --auto-episodes --feed-url https://example.com/podweaver/feed.xml
```

This uses temporary subscriptions and episode identities to check actual settings controls, bounded first selection, arrival order, duplicate prevention, queue removal, independent switches, the download cap, sharing a manual transfer, refill after a played marker, manual deletion, failed-transfer backoff, and backup compatibility. It downloads the shortest live enclosure twice under isolated identities and restores the original data and any pre-existing backup file. Reports and the settings screenshot are `auto-results.json` and `auto-settings.png`. No feedback is submitted. An interrupted run is restored on the next test-build launch.

To check playlist behavior and the cached-artwork crash on a jailbroken device:

```bash
python3 scripts/test-device.py --device-model iPod4,1 --install --playlist
```

This standalone scenario uses short local silent WAV files and a primed artwork cache. It exercises repeated Downloads reloads, deletion, native playlist options, action-sheet adding, persistent limits/backlog/order, notes compatibility, backup restoration, and real AVPlayer advancement. It preserves the original preferences and removes temporary files. Its report is `playlist-results.json`. This scenario passed on an iPod touch 4 running iOS 6.1.6 after a user-authorized Legacy iOS Kit jailbreak and AppSync installation. The separate original device that exhibited the Downloads crash was unavailable; this check exercises the synchronous cached-artwork path on the newly connected device.

Headless checks compile the actual persistent playlist, episode, podcast and backup models with small UIKit-free collaborators. They also stress the iOS 6 atomic compatibility implementation with concurrent unaligned increments:

```bash
bash scripts/test-playlist-models.sh
```

The test container extends the existing build image; it adds no host packages or app dependency. See [playlist validation](docs/playlist-validation.md) for the current verification scope.

`PODCOLD_DEBUG=1` signs only the test app executable with `get-task-allow` for debugging. `PODCOLD_DEVICE_TESTING=1` compiles the test runner; it runs only with the explicit `--podcold-device-test` launch argument. Both are off by default. Switching test mode invalidates cached objects. The `device_tested` field produced by static IPA verification stays false: the separate device-test report is the runtime evidence.

For stack inspection with the bundled Linux LLDB, `scripts/linux/Dockerfile.debug` adds its missing Python runtime to a separate image. This is optional; the automatic test does not need the debugger's expression evaluator.

## Build details

- [Theos](https://github.com/theos/theos): `dd7f2f4b245930942d872421ea26e420c106fc5f` (2022 revision).
- [Linux Swift iOS toolchain](https://github.com/kabiroberai/swift-toolchain-linux/releases/tag/v2.1.0): Swift 5.6.1 for Ubuntu 20.04, checked against a pinned SHA-256.
- [Theos SDKs](https://github.com/theos/sdks): `0222fd5413cf4b9af096f37b4621afa2688572f7`, using iPhoneOS 15.6.
- Ubuntu 20.04 container base pinned by image digest.
- Existing ARMv7 curl/OpenSSL archives and the 18 Swift runtime libraries from `build/podcold_ios6.ipa`.
- Apple's `libarclite_iphoneos.a` from the pinned toolchain, force-linked to supply legacy Objective-C class-registration support required by Swift on older iOS versions. Xcode adds this automatically; the Linux link driver needs an explicit flag.

The Swift resource directory must explicitly select Apple's libraries; otherwise the Linux compiler imports Linux CoreFoundation/Dispatch modules. Clang needs its Darwin compiler-runtime directory for the platform-version helper used by curl. Optional SDK Swift overlays are weak-linked. The package rewrites all references to its bundled Swift libraries to use `@rpath`, including references between runtime libraries. An iOS 6 allocation shim supplies `objc_allocWithZone` through the equivalent `allocWithZone:` message. An NSData fallback supplies the byte-range enumeration method used by Swift Data on iOS 6, and Playlist Options implements the initializer called internally by the older UITableViewController. These fixes were verified on iOS 6.1.6; the verifier now rejects system-path references to bundled runtimes and an unresolved allocation entry point.

Icons are copied from their original PNG sources; the build does not require Apple's asset-catalog compiler. All runtime libraries are reduced to ARMv7 and re-signed. Packaging verifies ZIP integrity, bundle identity, Mach-O architecture and minimum OS for every binary, code-signature presence, required bundled dependencies, the arclite class marker and weak registration import, and required app symbols against the original Swift runtime export tables. These are static checks, not a substitute for a device launch or a cryptographic signature validation.

iOS 6 also needs out-of-line 64-bit and generic atomic operations used by the OpenSSL archive. `atomic_stubs.c` provides these using a shared pthread mutex and alignment-safe copies.

The upstream `atomic_stubs.S` currently emits a linker warning about the alignment of its `.Lno` label. The application sources are retained; the separate device reports record the physical validation scope.

# Episode notes and listening flow validation

Checked on 2026-10-28 using the connected jailbroken iPod touch 4 (iPod4,1), iOS 7.1.2, with the Linux ARMv7 build.

- Eight rendering fixtures passed: labels/entities, encoded query separators, relative links, paragraph/list spacing, UTF-16 ranges, rejected non-web schemes and unrelated attributes, quoted tag delimiters, and plain text.
- The actual episode screen rendered three native feedback links with a read-only, selectable text view and its installed iOS 7 delegate.
- The Download button fetched a 2,833,056-byte MP3 from the live public mixed feed. The file and download record existed before playback started.
- The Play button started the downloaded episode. AVPlayer reported playing state, a valid duration and advancing playback time.
- The test invoked the text view’s installed delegate for the Listened link. Safari became the foreground app and loaded the public HTTPS confirmation page, verified from the device screenshot. No feedback form was submitted.
- With Safari in front for 40 seconds, the player remained in playing state and advanced at least 30 seconds.
- The test file was removed and saved recents, downloads, played markers and queue preferences were restored. The live feed’s listening progress and preferences were not changed.
- A separate subscription scenario passed all eleven RSS/Atom/URL validation fixtures, keyboard visibility, live feed loading, persisted subscription entry, and duplicate prevention. It restored the original subscriptions afterward.

These are device checks with native control actions and a delegate invocation, not simulated finger taps. They demonstrate a local download and playback continuing while Safari is open; they do not establish uninterrupted background downloading, lock-screen reliability over hours, or direct streaming from every publisher.

Local reports and screenshots are under `.build-linux/device-test/` and are intentionally not committed. Test code requires `PODCOLD_DEVICE_TESTING=1` plus an explicit launch argument. Regular builds omit it. Static IPA verification also checks that the iOS 7 link delegate selector is exported; its `device_tested` field remains false because the separate device report supplies runtime evidence.

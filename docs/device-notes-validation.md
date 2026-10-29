# Episode notes and listening flow validation

Checked on 2026-10-28 using the connected jailbroken iPod touch 4 (iPod4,1), iOS 7.1.2, with the Linux ARMv7 build.

- Eight rendering fixtures passed: labels/entities, encoded query separators, relative links, paragraph/list spacing, UTF-16 ranges, rejected non-web schemes and unrelated attributes, quoted tag delimiters, and plain text.
- The actual episode screen rendered native feedback links with a read-only, selectable text view and its installed iOS 7 delegate.
- The Download button fetched a 2,833,056-byte MP3 from the live public mixed feed. The file and download record existed before playback started.
- The Play button started the downloaded episode. AVPlayer reported playing state, a valid duration and advancing playback time.
- The test invoked the text view’s installed delegate for the Listened link. Safari became the foreground app and loaded the public HTTPS confirmation page, verified from the device screenshot. No feedback form was submitted.
- With Safari in front for 40 seconds, the player remained in playing state and advanced at least 30 seconds.
- The test file was removed and saved recents, downloads, played markers and queue preferences were restored. The live feed’s listening progress and preferences were not changed.
- A separate subscription scenario passed all fifteen RSS/Atom/URL validation fixtures, keyboard visibility, live feed loading, persisted subscription entry, and duplicate prevention. It restored the original subscriptions afterward.

These are device checks with native control actions and a delegate invocation, not simulated finger taps. They demonstrate a local download and playback continuing while Safari is open; they do not establish uninterrupted background downloading, lock-screen reliability over hours, or direct streaming from every publisher.

Local reports and screenshots are under `.build-linux/device-test/` and are intentionally not committed. Test code requires `PODCOLD_DEVICE_TESTING=1` plus an explicit launch argument. Regular builds omit it. Static IPA verification also checks that the iOS 7 link delegate selector is exported; its `device_tested` field remains false because the separate device report supplies runtime evidence.

## Original-author follow-up

The device checks were repeated after adding per-episode author support. RSS item author precedence, Atom entry authors, persisted episode authors, and backward compatibility with old saved episodes passed. The live episode screen showed its original creator in the byline, Now Playing showed the same creator, and `MPMediaItemPropertyArtist` carried that value for the lock screen. Podweaver’s live RSS also included explicit original podcast and author lines in the notes. Existing episode identities and listening progress were preserved.

## Sleep-timer follow-up

The native iOS 7 sleep menu exposes 15, 30, and 60 minutes, End of episode, Turn off, and Cancel. Physical-device checks verified every preset, replacement, cancellation, and the active end-of-episode label. Seeking the downloaded audio near its actual end verified that End of episode prevents queue advancement and preserves the queued item; disabling that option allows normal queue advancement again.

An accelerated eight-second deadline used the same timer path as the minute presets. The deadline survived reloading the player, paused audio with Safari in front, cleared itself, and preserved a nonzero playback position without further advancement. A temporary background task kept only the test reporter alive after audio paused. The normal build has no such task. The temporary download, played markers, recents, queue, and progress were restored afterward. This does not constitute a full 60-minute or locked-screen endurance test.

Run `scripts/test-device.py --sleep-timer --feed-url <public-podweaver-feed>` with a device-test build. `sleep-results.json` records the checks, and `sleep-menu.png` captures the native options. Regular builds exclude this scenario.

## Automatic episodes follow-up

The automatic-episode scenario uses temporary subscriptions and episode GUIDs, with the real shortest live audio enclosure. It exercises the native queue/download switches and limit stepper, checks a bounded first feed selection in playback order, and verifies that repeated observations, cache eviction, and queue removals do not re-add episodes. Automatic downloads work with queueing disabled, obey a global unplayed automatic-download cap, share a transfer with a simultaneous manual request, stop starting transfers while disabled, and refill when an episode is marked played. Deleting an automatic file does not download it again. Backup/export restores the new settings and arrival history; older backup metadata remains compatible.

Queue-table deletion is also exercised with queued change notifications pending. An intentionally unsupported enclosure scheme checks that a failed transfer saves a retry delay and does not retry immediately. These checks do not establish closed-app refreshing or unlimited background download execution: the normal scheduler starts feed checks and new transfers while active. Temporary data, files, preferences, and any existing same-day backup are restored after the check.

The automatic-episode scenario also passed on the newly jailbroken iPod touch 4 running iOS 6.1.6 on 2026-10-29, after the playlist options and Swift runtime compatibility fixes. This run includes the completed-download-to-playlist rule. See [playlist validation](playlist-validation.md) for its scope.

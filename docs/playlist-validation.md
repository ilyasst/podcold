# Playlist and Downloads validation — 2026-10-28

The update adds a dedicated view for the existing `play_queue`, independent automatic adding rules for new feed episodes and completed downloads, a 1–200 episode capacity, a bounded persistent waiting list, long-press episode actions, and backup support. The default capacity is 50. A full playlist retains its entries; waiting automatic additions refill free slots in order.

Downloads previously called `tableView.cellForRow(at:)` inside an artwork completion issued by `cellForRowAt`. A memory-cache hit calls completion synchronously, allowing recursive data-source calls while UIKit is still constructing that row. The fix captures the requested cell weakly and checks its episode identity. The original crashing device was unavailable, so this diagnosis has not yet been confirmed against its crash report.

## Completed checks

- Linux ARMv7 test and normal builds compile against the pinned SDK/toolchain. The package verifier checks all 19 binaries, their minimum OS, signatures, required symbols and dependencies.
- 38 checks compile and execute the actual persistent playlist, episode, podcast and backup models using the bundled Linux Swift toolchain. They cover capacity, duplicate prevention, reordering and reload, first-in-first-out refill, current/played exclusions, independent automatic rules, pending cancellation, bounded waiting state, backup restoration, old backups and URL normalization.
- The iOS 6 atomic fallback passes load/store/bitwise checks and 40,000 concurrent increments on an unaligned address using four pthreads. This is a host behavior check; ARMv7 compilation separately verifies the target ABI and symbol linkage.
- Python script compilation, shell syntax and `git diff --check` pass.

Run the headless checks with `bash scripts/test-playlist-models.sh`. Reports and build logs are stored locally under `.build-linux/`.

## Prepared device checks

`scripts/test-device.py --device-model iPod4,1 --install --playlist` runs an opt-in scenario with temporary identities, local three-second silent WAV files and a primed artwork cache. It repeatedly reloads Downloads with synchronous cached images, deletes a download, operates native options and playlist actions, checks notes compatibility and backups, and waits for two actual AVPlayer episodes to finish in order. A recovery record restores original preferences and removes temporary media even if the test is interrupted. The compiled test harness is excluded from the normal IPA.

The existing automatic-download scenario also checks that a completed transfer enters the playlist with new-episode adding disabled. Its settings checks now use Playlist Options. The sleep-timer scenario explicitly seeds its repeated temporary episode because normal manual adding excludes the currently playing episode.

## Device limitation

The newly connected iPod touch 4 runs iOS 6.1.6. The previous IPA was rejected with `DeviceOSVersionTooLow`. The build now targets iOS 6.0, guards iOS 7-only APIs, uses native link buttons for iOS 6 notes, and supplies the atomic operations absent from iOS 6 libSystem. Its packaged Swift libraries already target iOS 6.

The compatible package reached signature verification but installation failed with `ApplicationVerificationFailed`. The user confirmed this new device is not jailbroken and asked to finish the build without further device work. Installation needs jailbreak/AppSync or valid Apple development signing. No jailbreak, system change or app-data replacement was performed. The earlier jailbroken iPod showing the crash was not connected. The current changes therefore have build and headless validation, with physical-device verification still pending.

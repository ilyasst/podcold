# Playlist and Downloads validation — 2026-10-29

The update adds a dedicated view for the existing `play_queue`, independent automatic adding rules for new feed episodes and completed downloads, a 1–200 episode capacity, a bounded persistent waiting list, long-press episode actions, and backup support. The default capacity is 50. A full playlist retains its entries; waiting automatic additions refill free slots in order.

Downloads previously called `tableView.cellForRow(at:)` inside an artwork completion issued by `cellForRowAt`. A memory-cache hit calls completion synchronously, allowing recursive data-source calls while UIKit is still constructing that row. The fix captures the requested cell weakly and checks its episode identity. The original crashing device was unavailable, so this diagnosis has not yet been confirmed against its crash report.

## Completed checks

- Linux ARMv7 test and normal builds compile against the pinned SDK/toolchain. The package verifier checks all 19 binaries, their minimum OS, signatures, required symbols and dependencies.
- 38 checks compile and execute the actual persistent playlist, episode, podcast and backup models using the bundled Linux Swift toolchain. They cover capacity, duplicate prevention, reordering and reload, first-in-first-out refill, current/played exclusions, independent automatic rules, pending cancellation, bounded waiting state, backup restoration, old backups and URL normalization.
- The iOS 6 atomic fallback passes load/store/bitwise checks and 40,000 concurrent increments on an unaligned address using four pthreads. This is a host behavior check; ARMv7 compilation separately verifies the target ABI and symbol linkage.
- Python script compilation, shell syntax and `git diff --check` pass.

Run the headless checks with `bash scripts/test-playlist-models.sh`. Reports and build logs are stored locally under `.build-linux/`.

## Physical device checks

`scripts/test-device.py --device-model iPod4,1 --install --playlist` runs an opt-in scenario with temporary identities, local three-second silent WAV files and a primed artwork cache. It repeatedly reloads Downloads with synchronous cached images, deletes a download, operates native options and playlist actions, checks notes compatibility and backups, and waits for two actual AVPlayer episodes to finish in order. A recovery record restores original preferences and removes temporary media even if the test is interrupted. The compiled test harness is excluded from the normal IPA.

The existing automatic-download scenario also checks that a completed transfer enters the playlist with new-episode adding disabled. Its settings checks now use Playlist Options. The sleep-timer scenario explicitly seeds its repeated temporary episode because normal manual adding excludes the currently playing episode.

## iOS 6 compatibility and installation

The newly connected iPod touch 4 runs iOS 6.1.6. With the user's authorization, Legacy iOS Kit's jailbreak-only ramdisk workflow preserved the installed OS and user data after a completed backup. Cydia, Substrate and AppSync were installed, and the ad hoc IPA now installs successfully.

Actual device launches exposed additional compatibility requirements: bundled Swift dependencies must use app-relative `@rpath` install names; Swift's `objc_allocWithZone` entry point needs an Objective-C message fallback; Swift Data needs the NSData byte-range enumeration method absent from iOS 6; and UITableViewController's internal initializer call needs a Swift implementation in Playlist Options. These are included in the current build. The package verifier rejects system-path references to bundled Swift libraries and an unresolved allocation symbol.

The standalone playlist scenario passed on this iOS 6.1.6 iPod. All 22 boolean results, including the overall result, were true. The check covered 30 warm-cache Downloads reloads, deletion, independent automatic adding rules, capacity and backlog order, native settings controls, backup restoration, native notes links, action-sheet adding and two three-second local audio files completing in order through AVPlayer. Original preferences were restored and temporary media removed. Local evidence is `.build-linux/device-test/playlist-results.json`, with `playlist_downloads.png`, `playlist_ready.png` and `playlist-complete.png`.

The original iPod that exhibited the reported Downloads crash was unavailable. The cached-artwork regression has been exercised on this newly connected device; its original crash report has not been inspected. This scenario uses local media and does not by itself verify live network downloads or long listening sessions on iOS 6.

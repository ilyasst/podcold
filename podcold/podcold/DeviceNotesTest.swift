#if PODCOLD_DEVICE_TESTING
import UIKit
import MediaPlayer

// Opt-in physical-device checks. Only GET opens in Safari; no feedback is submitted.
// A temporary episode identity isolates downloads, recents, positions and played state.
enum DeviceNotesTest {
    private static var navigation: UINavigationController?
    private static var detail: EpisodeDetailVC?
    private static var episode: Episode?
    private static var checks: [String: Any] = [:]
    private static var attempts = 0
    private static var finishing = false
    private static var testingSleep = false
    private static var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private static let recoveryKey = "podcold_device_notes_restore"

    private static func views(_ root: UIView) -> [UIView] { [root] + root.subviews.flatMap { views($0) } }

    @discardableResult
    static func restoreInterruptedTest() -> Bool {
        let defaults = UserDefaults.standard
        guard let recovery = defaults.dictionary(forKey: recoveryKey),
              let values = recovery["values"] as? [String: Any], let missing = recovery["missing"] as? [String],
              let guid = recovery["guid"] as? String else { return true }
        let test = Episode(); test.guid = guid
        try? FileManager.default.removeItem(atPath: test.localPathForWriting())
        try? FileManager.default.removeItem(atPath: test.localPathForWriting() + ".part")
        for (key, value) in values { defaults.set(value, forKey: key) }
        for key in missing { defaults.removeObject(forKey: key) }
        for key in ["pos_", "dur_"] { defaults.removeObject(forKey: key + guid) }
        defaults.removeObject(forKey: recoveryKey)
        defaults.synchronize()
        let restored = values.keys.reduce(into: [String: Any]()) { result, key in result[key] = defaults.object(forKey: key) }
        return NSDictionary(dictionary: values).isEqual(to: restored) && missing.allSatisfy { defaults.object(forKey: $0) == nil }
    }

    static func run(navigation: UINavigationController, sleepTimer: Bool = false) {
        testingSleep = sleepTimer
        self.navigation = navigation
        checks = [:]; finishing = false
        var feedURL = ""
        for arg in CommandLine.arguments {
            if arg.hasPrefix("--podcold-test-token=") { checks["run_token"] = String(arg.dropFirst(21)) }
            if arg.hasPrefix("--podcold-feed-url=") { feedURL = String(arg.dropFirst(19)) }
        }
        let fixtures = fixtureChecks()
        checks["notes_fixtures"] = fixtures
        checks["notes_validation"] = fixtures.values.allSatisfy { $0 }
        guard checks["notes_validation"] as? Bool == true else { finish("Notes fixture failed"); return }
        FeedParser.loadPodcast(feedUrl: feedURL) { result in
            switch result {
            case .failure: finish("Live feed could not be loaded")
            case .success(let feed):
                guard let original = feed.episodes.filter({ $0.totalDuration() > 20 })
                    .min(by: { $0.totalDuration() < $1.totalDuration() }) else {
                    finish("Live feed has no suitable audio episode"); return
                }
                let test = Episode.from(dict: original.toDict())
                test.guid = "device-notes-" + (checks["run_token"] as? String ?? UUID().uuidString)
                episode = test
                let keys = [Episode.recentsKey, Episode.downloadsKey, Episode.playedGuidsKey, PlayQueue.storageKey]
                var saved: [String: Any] = [:], missing: [String] = []
                for key in keys {
                    if let value = UserDefaults.standard.object(forKey: key) { saved[key] = value }
                    else { missing.append(key) }
                }
                UserDefaults.standard.set(["values": saved, "missing": missing, "guid": test.guid], forKey: recoveryKey)
                UserDefaults.standard.synchronize()
                let screen = EpisodeDetailVC(episode: test, podcast: feed.podcast)
                detail = screen
                navigation.pushViewController(screen, animated: false)
                attempts = 0
                inspectNotes()
            }
        }
    }

    private static func inspectNotes() {
        guard let screen = detail,
              let notes = views(screen.view).first(where: { $0.accessibilityIdentifier == "episode-notes" }) as? UITextView else {
            finish("Episode notes view missing"); return
        }
        if (notes.attributedText?.length ?? 0) == 0 {
            attempts += 1
            if attempts > 15 { finish("Episode notes did not render"); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { inspectNotes() }; return
        }
        let links = linkRuns(notes.attributedText)
        checks["native_links"] = !notes.isEditable && notes.isSelectable && !notes.isScrollEnabled &&
            links.contains(where: { $0.0 == "Listened" }) && notes.delegate === screen
        checks["feedback_link_count"] = links.count
        let byline = views(screen.view).first(where: { $0.accessibilityIdentifier == "episode-author" }) as? UILabel
        checks["original_author_byline"] = !(episode?.author.isEmpty ?? true) && byline?.text == "By " + (episode?.author ?? "")
        notes.superview.map { parent in
            if let scroll = parent as? UIScrollView { scroll.scrollRectToVisible(notes.frame, animated: false) }
        }
        emit("notes_rendered")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard let button = views(screen.view).compactMap({ $0 as? UIButton }).first(where: { $0.title(for: .normal) == "Download" }) else {
                finish("Download button missing"); return
            }
            button.sendActions(for: .touchUpInside)
            checks["download_progress_ui"] = !button.isEnabled
            attempts = 0
            emit("download_started")
            pollDownload()
        }
    }

    private static func pollDownload() {
        guard let ep = episode else { finish("Test episode missing"); return }
        if let local = ep.localPath(),
           let attrs = try? FileManager.default.attributesOfItem(atPath: local),
           let size = attrs[.size] as? NSNumber, size.intValue > 0,
           Episode.loadDownloads().contains(where: { $0.guid == ep.guid }) {
            checks["download_bytes"] = size.intValue
            checks["download_saved"] = Episode.loadDownloads().contains(where: { $0.guid == ep.guid })
            guard let screen = detail,
                  let button = views(screen.view).compactMap({ $0 as? UIButton }).first(where: { $0.title(for: .normal) == "Play" }) else {
                finish("Play button missing"); return
            }
            button.sendActions(for: .touchUpInside)
            attempts = 0
            pollPlayback()
            return
        }
        attempts += 1
        if attempts >= 150 { finish("Download did not complete within 150 seconds"); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { pollDownload() }
    }

    private static func pollPlayback() {
        let player = AudioPlayer.shared
        if player.state == .playing && player.currentTime > 3 {
            checks["local_playback"] = player.currentEpisode?.guid == episode?.guid && player.duration > 20
            let nowAuthor = navigation.map { views($0.view).first(where: { $0.accessibilityIdentifier == "now-playing-author" }) as? UILabel } ?? nil
            checks["now_playing_author"] = nowAuthor?.text == episode?.author
            checks["lock_screen_author"] = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtist] as? String == episode?.author
            emit("playback_started")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if testingSleep { testSleepControls() } else { openFeedback() }
            }
            return
        }
        attempts += 1
        if player.state == .failed || attempts >= 40 { finish("Downloaded audio did not start playing"); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { pollPlayback() }
    }

    private static func testSleepControls() {
        guard let screen = navigation?.topViewController as? NowPlayingVC,
              let button = views(screen.view).first(where: { $0.accessibilityIdentifier == "sleep-timer" }) as? UIButton else {
            finish("Sleep button missing"); return
        }
        if let scroll = button.superview?.superview as? UIScrollView {
            scroll.scrollRectToVisible(button.convert(button.bounds, to: scroll), animated: false)
        }
        button.sendActions(for: .touchUpInside)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let roots = UIApplication.shared.windows.flatMap { views($0) }
            guard let sheet = roots.compactMap({ $0 as? UIActionSheet }).first(where: { $0.accessibilityIdentifier == "sleep-timer-menu" }) else {
                finish("Sleep menu did not open"); return
            }
            emit("sleep_menu")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                let titles = (0..<sheet.numberOfButtons).compactMap { sheet.buttonTitle(at: $0) }
                checks["sleep_menu_options"] = ["15 minutes", "30 minutes", "60 minutes", "End of episode", "Turn off", "Cancel"].allSatisfy { titles.contains($0) }
                let player = AudioPlayer.shared
                for minutes in [15, 30, 60] {
                    if let index = titles.firstIndex(of: "\(minutes) minutes") {
                        screen.actionSheet(sheet, clickedButtonAt: index)
                        let remaining = player.sleepTimerRemaining ?? 0
                        checks["sleep_\(minutes)_minutes"] = remaining > Double(minutes * 60 - 2) && remaining <= Double(minutes * 60)
                    }
                }
                if let cancel = titles.firstIndex(of: "Cancel") {
                    screen.actionSheet(sheet, clickedButtonAt: cancel)
                    checks["sleep_cancel_keeps_timer"] = (player.sleepTimerRemaining ?? 0) > 3598
                }
                if let off = titles.firstIndex(of: "Turn off") { screen.actionSheet(sheet, clickedButtonAt: off) }
                checks["sleep_off"] = !player.hasSleepTimer
                if let end = titles.firstIndex(of: "End of episode") { screen.actionSheet(sheet, clickedButtonAt: end) }
                checks["sleep_end_selected"] = player.sleepsAtEpisodeEnd && button.title(for: .normal) == "Sleep at end of episode"
                sheet.dismiss(withClickedButtonIndex: sheet.cancelButtonIndex, animated: false)
                // Isolate the user's real queue. Repeating this temporary episode also
                // avoids leaving any additional episode's progress keys behind.
                UserDefaults.standard.set([], forKey: PlayQueue.storageKey)
                PlayQueue.shared.reload()
                if let ep = episode { PlayQueue.shared.add(ep) }
                player.seek(to: player.duration - 2)
                attempts = 0
                pollSleepEnd()
            }
        }
    }

    private static func pollSleepEnd() {
        let player = AudioPlayer.shared
        if player.state == .ended {
            checks["sleep_end_preserves_queue"] = PlayQueue.shared.episodes.count == 1 && !player.hasSleepTimer
            // Cancelling end-of-episode must restore ordinary queue advancement.
            player.resume()
            player.sleepAtEndOfEpisode()
            player.cancelSleepTimer()
            player.seek(to: player.duration - 2)
            attempts = 0
            pollSleepQueue()
            return
        }
        attempts += 1
        if attempts >= 15 { finish("End-of-episode timer did not stop audio"); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { pollSleepEnd() }
    }

    private static func pollSleepQueue() {
        let player = AudioPlayer.shared
        if PlayQueue.shared.episodes.isEmpty && player.state == .playing && player.currentTime > 1 {
            checks["sleep_cancel_restores_queue"] = !player.hasSleepTimer && player.currentTime < 20
            // Verify the timer survives a player reload, then wait for actual
            // audio before measuring its short background stop deadline.
            player.setSleepTimer(seconds: 60)
            let remaining = player.sleepTimerRemaining ?? 0
            if let ep = episode { player.play(episode: ep) }
            checks["sleep_deadline_survives_episode_change"] = (player.sleepTimerRemaining ?? 0) <= remaining && player.hasSleepTimer
            attempts = 0
            pollSleepReload()
            return
        }
        attempts += 1
        if attempts >= 20 { finish("Queue did not advance after disabling sleep timer"); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { pollSleepQueue() }
    }

    private static func pollSleepReload() {
        let player = AudioPlayer.shared
        if player.state == .playing && player.currentTime > 1 {
            guard let screen = detail,
                  let notes = views(screen.view).first(where: { $0.accessibilityIdentifier == "episode-notes" }) as? UITextView,
                  let link = linkRuns(notes.attributedText).first(where: { $0.0 == "Listened" }) else {
                finish("Feedback link missing for background timer test"); return
            }
            player.setSleepTimer(seconds: 8)
            checks["sleep_background_start_position"] = player.currentTime
            backgroundTask = UIApplication.shared.beginBackgroundTask(expirationHandler: nil)
            emit("sleep_background")
            _ = screen.textView(notes, shouldInteractWith: link.1, in: link.2)
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                checks["sleep_background_pause"] = UIApplication.shared.applicationState == .background && player.state == .paused && !player.hasSleepTimer
                let position = player.currentTime
                checks["sleep_stop_position"] = position
                checks["sleep_saved_position"] = episode?.savedPosition() ?? 0
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    checks["sleep_position_preserved"] = position > 0 && abs(player.currentTime - position) < 1 && player.currentEpisode?.guid == episode?.guid && (episode?.savedPosition() ?? 0) > 0
                    finish(nil)
                }
            }
            return
        }
        attempts += 1
        if attempts >= 40 { finish("Audio did not restart before background sleep check"); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { pollSleepReload() }
    }

    private static func openFeedback() {
        guard let screen = detail,
              let notes = views(screen.view).first(where: { $0.accessibilityIdentifier == "episode-notes" }) as? UITextView,
              let link = linkRuns(notes.attributedText).first(where: { $0.0 == "Listened" }) else {
            finish("Listened link missing"); return
        }
        let start = AudioPlayer.shared.currentTime
        emit("opening_feedback")
        _ = screen.textView(notes, shouldInteractWith: link.1, in: link.2)
        DispatchQueue.main.asyncAfter(deadline: .now() + 40) {
            checks["safari_background"] = UIApplication.shared.applicationState == .background
            checks["background_playback"] = AudioPlayer.shared.state == .playing && AudioPlayer.shared.currentTime >= start + 30
            finish(nil)
        }
    }

    private static func linkRuns(_ text: NSAttributedString) -> [(String, URL, NSRange)] {
        var links: [(String, URL, NSRange)] = []
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length), options: []) { value, range, _ in
            if let url = value as? URL { links.append(((text.string as NSString).substring(with: range), url, range)) }
        }
        return links
    }

    private static func fixtureChecks() -> [String: Bool] {
        let base = "https://example.invalid/feed.xml"
        let html = "<p>🎧 Notes &#8217; &amp; details</p><p><a HREF=\"https://example.invalid/more?a=1&amp;b=2\">More <strong>like</strong> this</a> | <a href='/undo'>Undo</a> | <a href=https://example.invalid/listened>Listened</a></p><ul><li>First</li><li>Second</li></ul>"
        let rendered = EpisodeDetailVC.renderNotes(html, baseURL: base)
        let links = linkRuns(rendered)
        let bad = EpisodeDetailVC.renderNotes("<a href='javascript:alert(1)'>Bad</a><a href='file:///tmp/x'>File</a><a data-href='https://example.invalid/hidden'>No href</a><a title=\"a href='https://example.invalid/fake'\">Title only</a>", baseURL: base)
        let quoted = EpisodeDetailVC.renderNotes("<a title='a > b' href='https://example.invalid/x'>Quoted</a>", baseURL: base)
        return [
            "labels_and_entities": rendered.string.contains("🎧 Notes ’ & details") && links.map { $0.0 }.joined() == "More like thisUndoListened",
            "href_entities": links.first?.1.absoluteString == "https://example.invalid/more?a=1&b=2",
            "relative_href": links.count == 3 && links[1].1.absoluteString == "https://example.invalid/undo",
            "paragraphs_and_bullets": rendered.string.contains("\n\n") && rendered.string.contains("• First\n• Second"),
            "utf16_ranges": links.allSatisfy { (rendered.string as NSString).substring(with: $0.2) == $0.0 },
            "unsafe_schemes_and_attributes": linkRuns(bad).isEmpty,
            "quoted_tag_delimiter": linkRuns(quoted).first?.0 == "Quoted",
            "plain_text": EpisodeDetailVC.renderNotes("Just text", baseURL: base).string == "Just text"
        ]
    }

    private static func finish(_ error: String?) {
        guard !finishing else { return }; finishing = true
        AudioPlayer.shared.stop()
        AudioPlayer.shared.waitForBackgroundWrites {
            let restored = restoreInterruptedTest()
            PlayQueue.shared.reload()
            checks["test_data_restored"] = restored && UserDefaults.standard.object(forKey: recoveryKey) == nil && episode?.localPath() == nil
            var required = ["notes_validation", "native_links", "original_author_byline", "now_playing_author", "lock_screen_author", "download_progress_ui", "download_saved", "local_playback", "safari_background", "background_playback", "test_data_restored"]
            if testingSleep {
                required.removeAll { ["safari_background", "background_playback"].contains($0) }
                required += ["sleep_menu_options", "sleep_15_minutes", "sleep_30_minutes", "sleep_60_minutes", "sleep_cancel_keeps_timer", "sleep_off", "sleep_end_selected", "sleep_end_preserves_queue", "sleep_cancel_restores_queue", "sleep_deadline_survives_episode_change", "sleep_background_pause", "sleep_position_preserved"]
            }
            checks["passed"] = error == nil && required.allSatisfy { checks[$0] as? Bool == true }
            if let message = error { checks["error"] = message }
            emit("complete")
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
            navigation = nil; detail = nil; episode = nil
        }
    }

    private static func emit(_ stage: String) {
        var report = checks; report["stage"] = stage
        if let data = try? JSONSerialization.data(withJSONObject: report, options: []),
           let text = String(data: data, encoding: .utf8) { NSLog("PODCOLD_DEVICE_TEST %@", text) }
    }
}
#endif

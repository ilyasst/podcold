#if PODCOLD_DEVICE_TESTING
import UIKit

// No real subscriptions, feedback or media are changed. Local silent WAV files
// exercise actual AVPlayer completion and the persistent playlist on old devices.
enum DevicePlaylistTest {
    private static let recoveryKey = "podcold_device_playlist_restore"
    private static var checks: [String: Any] = [:]
    private static var navigation: UINavigationController?
    private static var fixtures: [Episode] = []
    private static var attempts = 0

    @discardableResult
    static func restoreInterruptedTest() -> Bool {
        let ud = UserDefaults.standard
        guard let recovery = ud.dictionary(forKey: recoveryKey),
              let values = recovery["values"] as? [String: Any],
              let missing = recovery["missing"] as? [String], let ids = recovery["guids"] as? [String] else { return true }
        for guid in ids {
            let ep = Episode(); ep.guid = guid
            try? FileManager.default.removeItem(atPath: ep.localPathForWriting())
            for prefix in ["pos_", "dur_"] { ud.removeObject(forKey: prefix + guid) }
        }
        if let path = recovery["backupPath"] as? String {
            if let data = recovery["backupData"] as? Data { try? data.write(to: URL(fileURLWithPath: path), options: .atomic) }
            else { try? FileManager.default.removeItem(atPath: path) }
        }
        for (key, value) in values { ud.set(value, forKey: key) }
        for key in missing { ud.removeObject(forKey: key) }
        ud.removeObject(forKey: recoveryKey); ud.synchronize()
        let restored = values.keys.reduce(into: [String: Any]()) { $0[$1] = ud.object(forKey: $1) }
        return NSDictionary(dictionary: values).isEqual(to: restored) && missing.allSatisfy { ud.object(forKey: $0) == nil }
    }

    static func run(navigation: UINavigationController) {
        self.navigation = navigation
        checks = [:]
        let token = CommandLine.arguments.first(where: { $0.hasPrefix("--podcold-test-token=") }).map { String($0.dropFirst(21)) } ?? UUID().uuidString
        checks["run_token"] = token
        let keys = [Podcast.subscriptionsKey, Episode.downloadsKey, Episode.recentsKey, Episode.playedGuidsKey,
                    PlayQueue.storageKey, PlayQueue.pendingKey, PlayQueue.downloadedKey, PlayQueue.limitKey,
                    AutoEpisodeManager.queueKey, AutoEpisodeManager.stateKey, AutoEpisodeManager.downloadKey,
                    Episode.autoDeleteKey, "latest_episode_cache"]
        let ud = UserDefaults.standard
        var values: [String: Any] = [:], missing: [String] = []
        for key in keys { if let value = ud.object(forKey: key) { values[key] = value } else { missing.append(key) } }
        fixtures = (0..<4).map {
            let ep = Episode(); ep.guid = "device-playlist-" + token + "-\($0)"
            ep.title = "Playlist test \($0 + 1)"; ep.podcastTitle = "Playlist device test"
            ep.duration = "3"; ep.audioUrl = "https://example.invalid/test.wav"
            ep.artworkUrl = "https://example.invalid/playlist-test.png"
            ep.summary = "<a href=\"https://example.invalid/more\">More like this</a> | <a href=\"https://example.invalid/batch\">Send another batch</a><p>Device test notes.</p>"
            return ep
        }
        ud.set(["values": values, "missing": missing, "guids": fixtures.map { $0.guid }], forKey: recoveryKey); ud.synchronize()
        ud.set([], forKey: PlayQueue.storageKey); ud.set([], forKey: PlayQueue.pendingKey)
        ud.set([], forKey: Episode.downloadsKey); ud.set([], forKey: Episode.playedGuidsKey)
        Podcast.saveSubscriptions([])
        Episode.autoDeleteFinished = false
        PlayQueue.shared.reload(); PlayQueue.maximumSize = 2
        AutoEpisodeManager.queueEnabled = false; AutoEpisodeManager.downloadEnabled = false
        PlayQueue.addDownloads = false
        do { for ep in fixtures { try wave().write(to: URL(fileURLWithPath: ep.localPathForWriting())) } }
        catch { finish("Could not create local audio"); return }
        UIGraphicsBeginImageContext(CGSize(width: 16, height: 16))
        UIColor.purple.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 16, height: 16))
        if let image = UIGraphicsGetImageFromCurrentImageContext() { AsyncImageView.primeCellForTest(url: fixtures[0].artworkUrl, image: image) }
        UIGraphicsEndImageContext()
        testRules()
    }

    private static func testRules() {
        let queue = PlayQueue.shared
        checks["manual_limit"] = queue.add(fixtures[0]) && queue.add(fixtures[1]) && !queue.add(fixtures[2]) && queue.episodes.count == 2
        checks["duplicate_noop"] = queue.add(fixtures[0]) && queue.episodes.count == 2
        queue.move(from: 0, to: 1)
        checks["reorder_persists"] = queue.episodes.map { $0.guid } == [fixtures[1].guid, fixtures[0].guid]
        queue.reload()
        checks["reload_keeps_order"] = queue.episodes.first?.guid == fixtures[1].guid
        queue.offerAutomatically(fixtures[2], source: .download)
        checks["download_switch_off"] = (UserDefaults.standard.array(forKey: PlayQueue.pendingKey) ?? []).isEmpty
        PlayQueue.addDownloads = true
        queue.offerAutomatically(fixtures[2], source: .download)
        checks["full_playlist_waits"] = !queue.contains(guid: fixtures[2].guid) && (UserDefaults.standard.array(forKey: PlayQueue.pendingKey) ?? []).count == 1
        queue.remove(guid: fixtures[1].guid); queue.fillAvailableSlots()
        checks["vacancy_refills_in_order"] = queue.episodes.map { $0.guid } == [fixtures[0].guid, fixtures[2].guid]
        PlayQueue.maximumSize = 1
        checks["lower_limit_keeps_entries"] = queue.episodes.count == 2 && !queue.add(fixtures[3])
        PlayQueue.maximumSize = 2
        queue.offerAutomatically(fixtures[3], source: .newEpisode)
        checks["new_episode_switch_off"] = (UserDefaults.standard.array(forKey: PlayQueue.pendingKey) ?? []).isEmpty
        AutoEpisodeManager.queueEnabled = true
        queue.offerAutomatically(fixtures[3], source: .newEpisode)
        AutoEpisodeManager.queueEnabled = false; queue.fillAvailableSlots()
        checks["disabled_pending_discarded"] = (UserDefaults.standard.array(forKey: PlayQueue.pendingKey) ?? []).isEmpty
        Episode.markPlayed(guid: fixtures[3].guid)
        queue.offerAutomatically(fixtures[3], source: .download)
        checks["played_excluded"] = !queue.contains(guid: fixtures[3].guid)
        for ep in fixtures.prefix(3) { Episode.addToDownloads(ep) }
        testDownloads()
    }

    private static func testDownloads() {
        let screen = DownloadsVC()
        navigation?.pushViewController(screen, animated: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard let table = screen.view.subviews.compactMap({ $0 as? UITableView }).first else { finish("Downloads table missing"); return }
            // The original implementation recursively calls cellForRowAt here on
            // a memory-cache hit. Repeat both real UIKit reloads and data-source calls.
            for _ in 0..<30 {
                table.reloadData(); table.layoutIfNeeded()
                for row in 0..<3 {
                    let cell = screen.tableView(table, cellForRowAt: IndexPath(row: row, section: 0))
                    if cell.imageView?.image == nil { checks["warm_download_artwork"] = false }
                }
            }
            if checks["warm_download_artwork"] == nil { checks["warm_download_artwork"] = true }
            checks["downloads_long_press"] = table.gestureRecognizers?.contains(where: { $0 is UILongPressGestureRecognizer }) ?? false
            screen.tableView(table, commit: .delete, forRowAt: IndexPath(row: 0, section: 0))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                checks["download_delete_stable"] = table.numberOfRows(inSection: 0) == 2 && Episode.loadDownloads().count == 2
                emit("playlist_downloads")
                testOptions()
            }
        }
    }

    private static func testOptions() {
        let screen = PlaylistSettingsVC()
        navigation?.pushViewController(screen, animated: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard let table = screen.tableView else { finish("Playlist options missing"); return }
            let newToggle = table.cellForRow(at: IndexPath(row: 0, section: 0))?.accessoryView as? UISwitch
            let downloadToggle = table.cellForRow(at: IndexPath(row: 1, section: 0))?.accessoryView as? UISwitch
            let limit = table.cellForRow(at: IndexPath(row: 2, section: 0))?.accessoryView as? UIStepper
            newToggle?.isOn = true; newToggle?.sendActions(for: .valueChanged)
            downloadToggle?.isOn = false; downloadToggle?.sendActions(for: .valueChanged)
            limit?.value = 4; limit?.sendActions(for: .valueChanged)
            checks["settings_controls_persist"] = AutoEpisodeManager.queueEnabled && !PlayQueue.addDownloads && PlayQueue.maximumSize == 4
            testBackup()
            testNotesAndActions()
        }
    }

    private static func testBackup() {
        let ud = UserDefaults.standard
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first!
        let path = (docs as NSString).appendingPathComponent("podcold-backup-" + formatter.string(from: Date()) + ".json")
        var recovery = ud.dictionary(forKey: recoveryKey) ?? [:]; recovery["backupPath"] = path
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) { recovery["backupData"] = data }
        ud.set(recovery, forKey: recoveryKey); ud.synchronize()
        guard let result = BackupManager.export(), let backup = BackupManager.parse(filePath: result.filePath) else { checks["backup_playlist_options"] = false; return }
        PlayQueue.addDownloads = true; PlayQueue.maximumSize = 8
        BackupManager.applyImport(backup, mode: .replace)
        checks["backup_playlist_options"] = !PlayQueue.addDownloads && PlayQueue.maximumSize == 4 && backup.playlistMaximumSize == 4
    }

    private static func testNotesAndActions() {
        let podcast = Podcast(); podcast.title = "Device test"
        let screen = EpisodeDetailVC(episode: fixtures[0], podcast: podcast)
        navigation?.pushViewController(screen, animated: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            func views(_ root: UIView) -> [UIView] { return [root] + root.subviews.flatMap { views($0) } }
            let all = views(screen.view)
            if #available(iOS 7.0, *) {
                checks["notes_compatible"] = all.contains { $0.accessibilityIdentifier == "episode-notes" }
            } else {
                checks["notes_compatible"] = all.contains { $0.accessibilityIdentifier == "episode-notes-legacy" } && all.compactMap { $0 as? UIButton }.contains { $0.title(for: .normal) == "Send another batch" }
            }
            PlayQueue.shared.remove(guid: fixtures[0].guid)
            let actions = EpisodePlaylistActions()
            actions.show(episode: fixtures[0], in: screen.view)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let sheet = UIApplication.shared.windows.flatMap { views($0) }.compactMap { $0 as? UIActionSheet }.first
                actions.actionSheet(sheet ?? UIActionSheet(), clickedButtonAt: 0)
                sheet?.dismiss(withClickedButtonIndex: 0, animated: false)
                checks["hold_action_adds"] = PlayQueue.shared.contains(guid: fixtures[0].guid)
                testPlayback()
            }
        }
    }

    private static func testPlayback() {
        let ud = UserDefaults.standard
        ud.set(fixtures.prefix(2).map { $0.toDict() }, forKey: PlayQueue.storageKey)
        ud.set([], forKey: PlayQueue.pendingKey); PlayQueue.shared.reload()
        let screen = PlaylistVC(); navigation?.pushViewController(screen, animated: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard let button = screen.view.subviews.flatMap({ $0.subviews }).flatMap({ [$0] + $0.subviews }).compactMap({ $0 as? UIButton }).first(where: { $0.accessibilityIdentifier == "play-playlist" }) else { finish("Play playlist button missing"); return }
            emit("playlist_ready")
            button.sendActions(for: .touchUpInside)
            attempts = 0; pollPlayback()
        }
    }

    private static func pollPlayback() {
        if AudioPlayer.shared.currentEpisode?.guid == fixtures[1].guid { checks["playlist_advances"] = true }
        if fixtures.prefix(2).allSatisfy({ Episode.isPlayed(guid: $0.guid) }) {
            checks["playlist_finishes_in_order"] = PlayQueue.shared.episodes.isEmpty && checks["playlist_advances"] as? Bool == true
            finish(nil); return
        }
        attempts += 1
        if attempts > 80 { finish("Local playlist playback did not finish"); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { pollPlayback() }
    }

    private static func wave() -> Data {
        let samples = 3 * 8000, bytes = samples * 2
        var data = Data()
        func text(_ value: String) { data.append(value.data(using: .ascii)!) }
        func number(_ value: UInt32, bytes: Int) { for shift in 0..<bytes { data.append(UInt8((value >> (shift * 8)) & 255)) } }
        text("RIFF"); number(UInt32(36 + bytes), bytes: 4); text("WAVEfmt ")
        number(16, bytes: 4); number(1, bytes: 2); number(1, bytes: 2)
        number(8000, bytes: 4); number(16000, bytes: 4); number(2, bytes: 2); number(16, bytes: 2)
        text("data"); number(UInt32(bytes), bytes: 4); data.append(Data(repeating: 0, count: bytes))
        return data
    }

    private static func finish(_ error: String?) {
        AudioPlayer.shared.stop()
        AudioPlayer.shared.waitForBackgroundWrites {
            navigation?.popToRootViewController(animated: false)
            checks["test_data_restored"] = restoreInterruptedTest()
            PlayQueue.shared.reload()
            let assertions = checks.values.compactMap { $0 as? Bool }
            checks["passed"] = error == nil && assertions.count >= 18 && assertions.allSatisfy { $0 }
            if let error = error { checks["error"] = error }
            emit("complete"); navigation = nil; fixtures = []
        }
    }

    private static func emit(_ stage: String) {
        var report = checks; report["stage"] = stage
        if let data = try? JSONSerialization.data(withJSONObject: report), let text = String(data: data, encoding: .utf8) { NSLog("PODCOLD_DEVICE_TEST %@", text) }
    }
}
#endif

#if PODCOLD_DEVICE_TESTING
import UIKit

// Exercises the real settings controls and scheduler with temporary identities.
// Only the shortest live enclosure is fetched; the public feed is never modified.
enum DeviceAutoEpisodeTest {
    private static let recoveryKey = "podcold_device_auto_restore"
    private static var checks: [String: Any] = [:]
    private static var navigation: UINavigationController?
    private static var fixtures: [Episode] = []
    private static var podcast: Podcast!
    private static var attempts = 0
    private static var finishing = false
    private static var manualJoined = false
    private static var exportedPath: String?

    @discardableResult
    static func restoreInterruptedTest() -> Bool {
        let defaults = UserDefaults.standard
        guard let saved = defaults.dictionary(forKey: recoveryKey),
              let values = saved["values"] as? [String: Any],
              let missing = saved["missing"] as? [String], let ids = saved["guids"] as? [String] else { return true }
        for guid in ids {
            let ep = Episode(); ep.guid = guid
            try? FileManager.default.removeItem(atPath: ep.localPathForWriting())
            try? FileManager.default.removeItem(atPath: ep.localPathForWriting() + ".part")
            defaults.removeObject(forKey: "pos_" + guid)
            defaults.removeObject(forKey: "dur_" + guid)
        }
        if let path = saved["backupPath"] as? String {
            if let data = saved["backupData"] as? Data { try? data.write(to: URL(fileURLWithPath: path), options: .atomic) }
            else { try? FileManager.default.removeItem(atPath: path) }
        }
        for (key, value) in values { defaults.set(value, forKey: key) }
        for key in missing { defaults.removeObject(forKey: key) }
        defaults.removeObject(forKey: recoveryKey)
        defaults.synchronize()
        var restored: [String: Any] = [:]
        for key in values.keys { restored[key] = defaults.object(forKey: key) }
        return NSDictionary(dictionary: values).isEqual(to: restored) && missing.allSatisfy { defaults.object(forKey: $0) == nil }
    }

    static func run(navigation: UINavigationController) {
        self.navigation = navigation
        checks = [:]; finishing = false; manualJoined = false
        var feedURL = ""
        for arg in CommandLine.arguments {
            if arg.hasPrefix("--podcold-test-token=") { checks["run_token"] = String(arg.dropFirst(21)) }
            if arg.hasPrefix("--podcold-feed-url=") { feedURL = String(arg.dropFirst(19)) }
        }
        FeedParser.loadPodcast(feedUrl: feedURL) { result in
            switch result {
            case .failure: finish("Live feed could not be loaded")
            case .success(let feed):
                guard let audio = feed.episodes.filter({ $0.totalDuration() > 20 }).min(by: { $0.totalDuration() < $1.totalDuration() }) else {
                    finish("No suitable live episode"); return
                }
                prepare(audio: audio)
                testSettings()
            }
        }
    }

    private static func prepare(audio: Episode) {
        let token = checks["run_token"] as? String ?? UUID().uuidString
        podcast = Podcast(); podcast.title = "Automatic episode test"
        podcast.feedUrl = "https://example.invalid/device-auto/" + token
        fixtures = (0..<9).map { index in
            let ep = Episode.from(dict: audio.toDict())
            ep.guid = "device-auto-" + token + "-" + String(index)
            ep.title = "Temporary episode " + String(index)
            ep.pubDate = "Wed, 28 Oct 2026 00:00:0\(index) +0000"
            return ep
        }
        let keys = [Podcast.subscriptionsKey, PlayQueue.storageKey, Episode.downloadsKey, Episode.recentsKey, Episode.playedGuidsKey,
                    AutoEpisodeManager.queueKey, AutoEpisodeManager.downloadKey, AutoEpisodeManager.limitKey, AutoEpisodeManager.stateKey,
                    UpNextManager.maxNewEpisodesKey, "latest_episode_cache", PlayQueue.limitKey, PlayQueue.pendingKey, PlayQueue.downloadedKey]
        let defaults = UserDefaults.standard
        var values: [String: Any] = [:], missing: [String] = []
        for key in keys {
            if let value = defaults.object(forKey: key) { values[key] = value } else { missing.append(key) }
        }
        defaults.set(["values": values, "missing": missing, "guids": fixtures.map { $0.guid }], forKey: recoveryKey)
        defaults.synchronize()
        Podcast.saveSubscriptions([podcast])
        defaults.removeObject(forKey: AutoEpisodeManager.stateKey)
        defaults.set([], forKey: PlayQueue.storageKey)
        defaults.set([], forKey: Episode.downloadsKey)
        defaults.set([], forKey: Episode.playedGuidsKey)
        PlayQueue.shared.reload()
        defaults.removeObject(forKey: PlayQueue.pendingKey)
        PlayQueue.maximumSize = 50
        PlayQueue.addDownloads = false
        AutoEpisodeManager.queueEnabled = true
        AutoEpisodeManager.downloadEnabled = false
        AutoEpisodeManager.downloadLimit = 1
        UpNextManager.maxNewEpisodes = 2
        AutoEpisodeManager.shared.onlyTestInputs = true
        AutoEpisodeManager.shared.suspendForTest(false)
    }

    private static func testSettings() {
        guard let nav = navigation else { finish("Navigation missing"); return }
        let options = PlaylistSettingsVC()
        nav.pushViewController(options, animated: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let queue = options.tableView.cellForRow(at: IndexPath(row: 0, section: 0))?.accessoryView as? UISwitch
            checks["playlist_queue_control"] = queue?.accessibilityIdentifier == "auto-queue"
            queue?.isOn = false; queue?.sendActions(for: .valueChanged)
            checks["queue_switch_persists"] = !AutoEpisodeManager.queueEnabled
            queue?.isOn = true; queue?.sendActions(for: .valueChanged)
            let screen = SettingsVC()
            nav.pushViewController(screen, animated: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard let table = screen.view.subviews.compactMap({ $0 as? UITableView }).first else { finish("Settings table missing"); return }
                table.scrollToRow(at: IndexPath(row: 2, section: 1), at: .middle, animated: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    let download = table.cellForRow(at: IndexPath(row: 1, section: 1))?.accessoryView as? UISwitch
                    let limit = table.cellForRow(at: IndexPath(row: 2, section: 1))?.accessoryView as? UIStepper
                    checks["settings_controls"] = checks["playlist_queue_control"] as? Bool == true && download?.accessibilityIdentifier == "auto-download" && limit?.accessibilityIdentifier == "auto-download-limit"
                    download?.isOn = true; download?.sendActions(for: .valueChanged)
                    checks["download_switch_persists"] = AutoEpisodeManager.downloadEnabled
                    download?.isOn = false; download?.sendActions(for: .valueChanged)
                    limit?.value = 2; limit?.sendActions(for: .valueChanged)
                    checks["limit_control_persists"] = AutoEpisodeManager.downloadLimit == 2
                    emit("auto_settings")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { testArrivals() }
                }
            }
        }
    }

    private static func testArrivals() {
        let manager = AutoEpisodeManager.shared
        manager.observe(feedURL: podcast.feedUrl, episodes: Array(fixtures[0...4].reversed()))
        checks["first_refresh_bounded_and_ordered"] = PlayQueue.shared.episodes.map { $0.guid } == [fixtures[3].guid, fixtures[4].guid]
        manager.observe(feedURL: podcast.feedUrl, episodes: Array(fixtures[0...4].reversed()))
        // Evict the display cache; automatic identity tracking must survive it.
        LatestEpisodeCache.clear()
        manager.observe(feedURL: podcast.feedUrl, episodes: Array(fixtures[0...5].reversed()))
        checks["refresh_deduplicates_and_appends"] = PlayQueue.shared.episodes.map { $0.guid } == [fixtures[3].guid, fixtures[4].guid, fixtures[5].guid]
        PlayQueue.shared.remove(guid: fixtures[4].guid)
        manager.observe(feedURL: podcast.feedUrl, episodes: Array(fixtures[0...5].reversed()))
        checks["removed_row_stays_removed"] = !PlayQueue.shared.contains(guid: fixtures[4].guid)
        // Let the actual table handle a deletion while queued-change notifications
        // are pending; a synchronous observer reload used to invalidate row counts.
        let screen = NowPlayingVC()
        navigation?.pushViewController(screen, animated: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard let table = screen.view.subviews.compactMap({ $0 as? UITableView }).first else { finish("Queue table missing"); return }
            screen.tableView(table, commit: .delete, forRowAt: IndexPath(row: 0, section: 0))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                checks["queue_table_delete"] = PlayQueue.shared.episodes.map { $0.guid } == [fixtures[5].guid] && table.numberOfRows(inSection: 0) == 1
                startDownloads()
            }
        }
    }

    private static func startDownloads() {
        let manager = AutoEpisodeManager.shared
        // Exercise disabled queue and enabled downloads independently.
        AutoEpisodeManager.queueEnabled = false
        PlayQueue.addDownloads = true
        AutoEpisodeManager.downloadEnabled = true
        AutoEpisodeManager.downloadLimit = 1
        manager.observe(feedURL: podcast.feedUrl, episodes: Array(fixtures[0...7].reversed()))
        checks["download_without_queue"] = !PlayQueue.shared.contains(guid: fixtures[6].guid) && !PlayQueue.shared.contains(guid: fixtures[7].guid)
        // A manual download of the same episode joins the running transfer.
        EpisodeDownloader.download(episode: fixtures[6], progress: { _ in }) { success in manualJoined = success }
        attempts = 0
        pollFirstDownload()
    }

    private static func pollFirstDownload() {
        if !AutoEpisodeManager.shared.isDownloadingForTest && fixtures[6].localPath() != nil {
            checks["automatic_download_saved"] = Episode.loadDownloads().contains(where: { $0.guid == fixtures[6].guid })
            checks["manual_download_joins"] = manualJoined
            checks["download_completion_adds_to_playlist"] = PlayQueue.shared.contains(guid: fixtures[6].guid)
            checks["download_cap_holds"] = fixtures[7].localPath() == nil
            // Turning downloading off must prevent a newly freed slot from starting.
            AutoEpisodeManager.downloadEnabled = false
            Episode.markPlayed(guid: fixtures[6].guid)
            AutoEpisodeManager.shared.reconcile()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                checks["disabled_download_stays_idle"] = !AutoEpisodeManager.shared.isDownloadingForTest && fixtures[7].localPath() == nil
                AutoEpisodeManager.downloadEnabled = true
                AutoEpisodeManager.shared.reconcile()
                attempts = 0; pollRefill()
            }
            return
        }
        attempts += 1
        if attempts >= 150 { finish("First automatic download did not finish"); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { pollFirstDownload() }
    }

    private static func pollRefill() {
        if !AutoEpisodeManager.shared.isDownloadingForTest && fixtures[7].localPath() != nil {
            checks["played_episode_refills_slot"] = Episode.loadDownloads().contains(where: { $0.guid == fixtures[7].guid })
            // Deleting an automatic download is an explicit decision; no redownload.
            fixtures[7].deleteDownload()
            AutoEpisodeManager.shared.reconcile()
            checks["deleted_download_stays_deleted"] = !AutoEpisodeManager.shared.isDownloadingForTest && fixtures[7].localPath() == nil
            fixtures[8].audioUrl = "bad-scheme://invalid"
            AutoEpisodeManager.shared.observe(feedURL: podcast.feedUrl, episodes: Array(fixtures.reversed()))
            attempts = 0; pollFailure()
            return
        }
        attempts += 1
        if attempts >= 150 { finish("Automatic refill did not finish"); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { pollRefill() }
    }

    private static func pollFailure() {
        if !AutoEpisodeManager.shared.isDownloadingForTest {
            let raw = UserDefaults.standard.dictionary(forKey: AutoEpisodeManager.stateKey) ?? [:]
            let items = raw["items"] as? [[String: Any]] ?? []
            let failed = items.first { ($0["episode"] as? [String: Any])?["guid"] as? String == fixtures[8].guid }
            checks["failed_download_backs_off"] = (failed?["retryAfter"] as? Double ?? 0) > Date().timeIntervalSince1970 && fixtures[8].localPath() == nil
            AutoEpisodeManager.shared.reconcile()
            checks["failed_download_not_retried_immediately"] = !AutoEpisodeManager.shared.isDownloadingForTest
            testBackup()
            return
        }
        attempts += 1
        if attempts >= 30 { finish("Failed transfer did not report a result"); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { pollFailure() }
    }

    private static func testBackup() {
        let defaults = UserDefaults.standard
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first!
        let path = (docs as NSString).appendingPathComponent("podcold-backup-" + fmt.string(from: Date()) + ".json")
        var recovery = defaults.dictionary(forKey: recoveryKey) ?? [:]
        recovery["backupPath"] = path
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) { recovery["backupData"] = data }
        defaults.set(recovery, forKey: recoveryKey); defaults.synchronize()
        guard let result = BackupManager.export(), let backup = BackupManager.parse(filePath: result.filePath) else {
            finish("Automatic settings backup failed"); return
        }
        AutoEpisodeManager.queueEnabled = true
        AutoEpisodeManager.downloadEnabled = false
        AutoEpisodeManager.downloadLimit = 20
        AutoEpisodeManager.shared.suspendForTest(true)
        BackupManager.applyImport(backup, mode: .replace)
        checks["backup_restores_settings_and_history"] = !AutoEpisodeManager.queueEnabled && AutoEpisodeManager.downloadEnabled && AutoEpisodeManager.downloadLimit == 1 && backup.autoEpisodeState != nil
        // An older backup should leave new preferences at their current values.
        let legacyPath = path + ".device-test"
        if let data = try? JSONSerialization.data(withJSONObject: ["version": 2, "subscriptions": []]) {
            try? data.write(to: URL(fileURLWithPath: legacyPath))
            if let legacy = BackupManager.parse(filePath: legacyPath) {
                checks["legacy_backup_compatible"] = legacy.autoQueue == nil && legacy.autoDownload == nil && legacy.autoDownloadLimit == nil
            }
            try? FileManager.default.removeItem(atPath: legacyPath)
        }
        finish(nil)
    }

    private static func finish(_ error: String?) {
        guard !finishing else { return }; finishing = true
        AutoEpisodeManager.shared.suspendForTest(true)
        AudioPlayer.shared.waitForBackgroundWrites {
            let restored = restoreInterruptedTest()
            PlayQueue.shared.reload()
            checks["test_data_restored"] = restored && fixtures.allSatisfy { $0.localPath() == nil }
            let required = ["settings_controls", "queue_switch_persists", "download_switch_persists", "limit_control_persists", "first_refresh_bounded_and_ordered", "refresh_deduplicates_and_appends", "removed_row_stays_removed", "queue_table_delete", "download_without_queue", "automatic_download_saved", "manual_download_joins", "download_completion_adds_to_playlist", "download_cap_holds", "disabled_download_stays_idle", "played_episode_refills_slot", "deleted_download_stays_deleted", "failed_download_backs_off", "failed_download_not_retried_immediately", "backup_restores_settings_and_history", "legacy_backup_compatible", "test_data_restored"]
            checks["passed"] = error == nil && required.allSatisfy { checks[$0] as? Bool == true }
            if let message = error { checks["error"] = message }
            emit("complete")
            navigation = nil; fixtures = []
        }
    }

    private static func emit(_ stage: String) {
        var report = checks; report["stage"] = stage
        if let data = try? JSONSerialization.data(withJSONObject: report), let text = String(data: data, encoding: .utf8) {
            NSLog("PODCOLD_DEVICE_TEST %@", text)
        }
    }
}
#endif

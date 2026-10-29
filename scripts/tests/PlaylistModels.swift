import Foundation

// Headless collaborators for the actual persistent model files. UIKit and
// AVPlayer remain covered by the opt-in physical-device scenario.
extension Notification.Name { static let episodeLibraryChanged = Notification.Name("test.library") }
class AudioPlayer { static let shared = AudioPlayer(); var currentEpisode: Episode? }
class AutoEpisodeManager {
    static let shared = AutoEpisodeManager()
    static let stateKey = "auto_episode_state_v1"
    static var queueEnabled = true
    static var downloadEnabled = false
    static var downloadLimit = 3
    static let limitRange = 1...20
    func settingsChanged() { PlayQueue.shared.fillAvailableSlots() }
}
enum UpNextManager { static var maxNewEpisodes = 3; static let maxNewEpisodesRange = 1...20 }
enum LatestEpisodeCache { static func clear() {} }

@main enum PlaylistModelTests {
    private static var count = 0
    private static func check(_ value: @autoclosure () -> Bool, _ label: String) {
        precondition(value(), label); count += 1
    }
    private static func episode(_ id: String) -> Episode { let ep = Episode(); ep.guid = id; ep.title = id; return ep }
    private static func reset() {
        let ud = UserDefaults.standard
        for key in [PlayQueue.storageKey, PlayQueue.pendingKey, PlayQueue.limitKey, PlayQueue.downloadedKey, Episode.playedGuidsKey] { ud.removeObject(forKey: key) }
        AudioPlayer.shared.currentEpisode = nil
        AutoEpisodeManager.queueEnabled = true; PlayQueue.addDownloads = true
        PlayQueue.shared.reload()
    }
    static func main() {
        reset()
        let queue = PlayQueue.shared, ud = UserDefaults.standard
        let a = episode("a"), b = episode("b"), c = episode("c"), d = episode("d")
        check(ud.object(forKey: PlayQueue.storageKey) == nil, "Reload must not create or rewrite saved state")
        check(PlayQueue.maximumSize == 50 && PlayQueue.addDownloads, "Default playlist options")
        PlayQueue.maximumSize = 2
        check(queue.add(a) && queue.add(b) && !queue.add(c), "Manual capacity enforced")
        check(queue.add(a) && queue.episodes.count == 2, "Duplicate is a no-op even at capacity")
        queue.move(from: 0, to: 1); queue.reload()
        check(queue.episodes.map { $0.guid } == ["b", "a"], "Reorder persists")
        PlayQueue.maximumSize = 1
        check(queue.episodes.count == 2 && !queue.add(c), "Lowering capacity preserves existing entries")
        PlayQueue.maximumSize = 2
        queue.offerAutomatically(c, source: .newEpisode)
        queue.offerAutomatically(d, source: .download)
        queue.reload(); queue.fillAvailableSlots()
        check(queue.episodes.map { $0.guid } == ["b", "a"], "Full playlist never evicts an entry")
        check((ud.array(forKey: PlayQueue.pendingKey) ?? []).count == 2, "Automatic backlog persists")
        queue.remove(guid: "b"); queue.fillAvailableSlots()
        check(queue.episodes.map { $0.guid } == ["a", "c"], "Backlog refills first-in first-out")
        queue.remove(guid: "d"); queue.remove(guid: "a"); queue.fillAvailableSlots()
        check(queue.episodes.map { $0.guid } == ["c"], "Removing a pending item cancels it")
        reset(); PlayQueue.maximumSize = 1
        AutoEpisodeManager.queueEnabled = false; PlayQueue.addDownloads = false
        queue.offerAutomatically(a, source: .newEpisode); queue.offerAutomatically(b, source: .download)
        check(queue.episodes.isEmpty, "Both automatic rules can be off")
        PlayQueue.addDownloads = true
        queue.offerAutomatically(b, source: .download)
        check(queue.episodes.map { $0.guid } == ["b"], "Downloads-only mode")
        queue.offerAutomatically(c, source: .download)
        AutoEpisodeManager.queueEnabled = true
        queue.offerAutomatically(c, source: .newEpisode)
        check((ud.array(forKey: PlayQueue.pendingKey) ?? []).count == 1, "Pending reasons deduplicate")
        PlayQueue.addDownloads = false
        queue.remove(guid: "b"); queue.fillAvailableSlots()
        check(queue.episodes.map { $0.guid } == ["c"], "Independent new-episode reason survives download switch-off")
        queue.offerAutomatically(d, source: .newEpisode)
        AutoEpisodeManager.queueEnabled = false; queue.fillAvailableSlots()
        check((ud.array(forKey: PlayQueue.pendingKey) ?? []).isEmpty, "Disabled automatic backlog is discarded")
        queue.remove(guid: "c"); queue.fillAvailableSlots()
        check(queue.episodes.isEmpty, "Manually removed episode stays removed")
        AutoEpisodeManager.queueEnabled = true
        Episode.markPlayed(guid: a.guid)
        queue.offerAutomatically(a, source: .newEpisode)
        check(queue.episodes.isEmpty, "Played arrivals excluded")
        AudioPlayer.shared.currentEpisode = b
        queue.offerAutomatically(b, source: .download)
        check(!queue.add(b) && queue.episodes.isEmpty, "Currently playing episode excluded")
        AudioPlayer.shared.currentEpisode = nil
        queue.add(c); queue.offerAutomatically(d, source: .newEpisode)
        let next = queue.next(); AudioPlayer.shared.currentEpisode = next
        queue.fillAvailableSlots()
        check(next?.guid == "c" && queue.episodes.map { $0.guid } == ["d"], "Advance refills without requeuing current episode")
        PlayQueue.maximumSize = 0; check(PlayQueue.maximumSize == 1, "Minimum clamped")
        PlayQueue.maximumSize = 999; check(PlayQueue.maximumSize == 200, "Maximum clamped")
        PlayQueue.maximumSize = 1
        for index in 0..<250 { queue.offerAutomatically(episode("pending-\(index)"), source: .newEpisode) }
        check((ud.array(forKey: PlayQueue.pendingKey) ?? []).count == 200, "Backlog memory bounded")
        PlayQueue.maximumSize = 2
        queue.offerAutomatically(episode("later-arrival"), source: .newEpisode)
        check(queue.episodes.map { $0.guid } == ["d", "pending-0"], "Waiting arrivals have priority over later automatic episodes")
        testBackup()
        testURLs()
        reset()
        print("Passed \(count) persistent playlist, backup and URL checks.")
    }

    private static func testBackup() {
        let file = "/tmp/podcold-playlist-model-backup.json"
        let payload: [String: Any] = ["version": 2, "subscriptions": [], "queue": [episode("saved").toDict()],
            "playlistAddDownloads": false, "playlistMaximumSize": 7,
            "playlistPending": [["episode": episode("waiting").toDict(), "sources": 2]]]
        try! JSONSerialization.data(withJSONObject: payload).write(to: URL(fileURLWithPath: file))
        let backup = BackupManager.parse(filePath: file)!
        check(backup.playlistAddDownloads == false && backup.playlistMaximumSize == 7, "Parse playlist backup preferences")
        BackupManager.applyImport(backup, mode: .replace)
        check(!PlayQueue.addDownloads && PlayQueue.maximumSize == 7 && PlayQueue.shared.episodes.map { $0.guid } == ["saved"], "Restore playlist and preferences")
        try! JSONSerialization.data(withJSONObject: ["version": 2, "queue": []]).write(to: URL(fileURLWithPath: file))
        let legacy = BackupManager.parse(filePath: file)!
        BackupManager.applyImport(legacy, mode: .replace)
        check(legacy.playlistMaximumSize == nil && !PlayQueue.addDownloads && PlayQueue.maximumSize == 7, "Old backups leave new preferences intact")
        try! JSONSerialization.data(withJSONObject: ["playlistMaximumSize": 500]).write(to: URL(fileURLWithPath: file))
        check(BackupManager.parse(filePath: file)?.playlistMaximumSize == nil, "Invalid imported limit ignored")
        try? FileManager.default.removeItem(atPath: file)
    }

    private static func testURLs() {
        for (input, expected) in [
            ("Example.COM/feed.xml", "https://example.com/feed.xml"),
            ("HTTPS://Example.COM:443/a%20b?x=1#fragment", "https://example.com/a%20b?x=1"),
            ("http://Example.COM:80/feed", "http://example.com/feed"),
            ("https://Example.COM:10000/feed.xml", "https://example.com:10000/feed.xml"),
            ("https://[::1]:10000/feed", "https://[::1]:10000/feed"),
            ("https://user:pass@EXAMPLE.com/feed", "https://user:pass@example.com/feed")
        ] { check(Podcast.normalizedFeedURL(input) == expected, "URL normalization: " + input) }
        for invalid in ["", "file:///tmp/feed", "https:///feed", "two words", "ftp://example.com"] {
            check(Podcast.normalizedFeedURL(invalid) == nil, "Reject invalid URL")
        }
    }
}

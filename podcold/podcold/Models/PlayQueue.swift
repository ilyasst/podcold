import Foundation

// Ordered list of episodes to play after the current one.
//
// The episode actually playing is NOT in here — AudioPlayer owns that — so the
// queue always reads as "up next" with no special-casing of row 0.
//
// Stored in UserDefaults next to recents. A queue is a handful of episodes, so
// the whole-plist rewrite UserDefaults performs on every change is affordable
// here in a way it is not for a 20-episode feed cache (which is why
// EpisodeListCache uses one plist per feed under Caches instead).
extension Notification.Name {
    static let playQueueChanged = Notification.Name("podcold.queue.changed")
}

class PlayQueue {
    static let shared = PlayQueue()
    private init() { episodes = PlayQueue.load() }

    // Internal so BackupManager can export/import it by key.
    static let storageKey = "play_queue"
    static let limitKey = "playlist_max_episodes"
    static let downloadedKey = "playlist_add_downloads"
    static let pendingKey = "playlist_pending_additions"
    static let limitRange = 1...200

    static var maximumSize: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: limitKey)
            return limitRange.contains(value) ? value : 50
        }
        set { UserDefaults.standard.set(min(200, max(1, newValue)), forKey: limitKey) }
    }

    static var addDownloads: Bool {
        get { return UserDefaults.standard.object(forKey: downloadedKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: downloadedKey) }
    }

    enum AutomaticSource: Int { case newEpisode = 1, download = 2 }

    private(set) var episodes: [Episode]
    private var notifying = false

    private static func load() -> [Episode] {
        guard let arr = UserDefaults.standard.array(forKey: storageKey) as? [[String: Any]] else { return [] }
        return arr.map { Episode.from(dict: $0) }
    }

    // The singleton caches `episodes` in memory, so anything that writes the
    // UserDefaults key directly (BackupManager import) must tell it to re-read.
    func reload() { episodes = PlayQueue.load(); notifyChange() }

    private func save() {
        UserDefaults.standard.set(episodes.map { $0.toDict() }, forKey: PlayQueue.storageKey)
        notifyChange()
    }

    private func notifyChange() {
        guard !notifying else { return }
        notifying = true
        DispatchQueue.main.async {
            self.notifying = false
            NotificationCenter.default.post(name: .playQueueChanged, object: self)
        }
    }

    func contains(guid: String) -> Bool {
        return episodes.contains { $0.guid == guid }
    }

    @discardableResult
    func add(_ episode: Episode) -> Bool {
        return append(episode, rollingFeed: nil)
    }

    private var hasOrdinaryRoom: Bool {
        return episodes.lazy.filter { $0.rollingFeed == nil }.count < PlayQueue.maximumSize
    }

    private func append(_ episode: Episode, rollingFeed: String?) -> Bool {
        guard !contains(guid: episode.guid) else { return true }
        guard rollingFeed != nil || hasOrdinaryRoom,
              AudioPlayer.shared.currentEpisode?.guid != episode.guid else { return false }
        removePending(guid: episode.guid)
        let entry = Episode.from(dict: episode.toDict())
        entry.rollingFeed = rollingFeed
        episodes.append(entry)
        save()
        return true
    }

    // Automatic arrivals wait for room rather than displacing the user's choices.
    // The bounded backlog is independent of feed caches and survives a restart.
    func offerAutomatically(_ episode: Episode, source: AutomaticSource, rollingFeed: String? = nil) {
        fillAvailableSlots()
        guard enabled(source.rawValue), !Episode.isPlayed(guid: episode.guid),
              AudioPlayer.shared.currentEpisode?.guid != episode.guid,
              !contains(guid: episode.guid) else { return }
        if append(episode, rollingFeed: rollingFeed) { return }
        var pending = pendingAdditions
        if let index = pending.firstIndex(where: { ($0["episode"] as? [String: Any])?["guid"] as? String == episode.guid }) {
            pending[index]["sources"] = (pending[index]["sources"] as? Int ?? 0) | source.rawValue
        } else if pending.count < 200 {
            var record = episode.toDict()
            record.removeValue(forKey: "rollingFeed")
            pending.append(["episode": record, "sources": source.rawValue])
        }
        pendingAdditions = pending
    }

    private var pendingAdditions: [[String: Any]] {
        get { return UserDefaults.standard.array(forKey: PlayQueue.pendingKey) as? [[String: Any]] ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: PlayQueue.pendingKey) }
    }

    private func enabled(_ sources: Int) -> Bool {
        return (sources & 1 != 0 && AutoEpisodeManager.queueEnabled) ||
               (sources & 2 != 0 && PlayQueue.addDownloads)
    }

    private func removePending(guid: String) {
        pendingAdditions = pendingAdditions.filter { ($0["episode"] as? [String: Any])?["guid"] as? String != guid }
    }

    func fillAvailableSlots() {
        var remaining: [[String: Any]] = []
        var changed = false
        for item in pendingAdditions {
            guard enabled(item["sources"] as? Int ?? 0),
                  let raw = item["episode"] as? [String: Any] else { continue }
            let ep = Episode.from(dict: raw)
            guard !Episode.isPlayed(guid: ep.guid), !contains(guid: ep.guid),
                  AudioPlayer.shared.currentEpisode?.guid != ep.guid else { continue }
            if hasOrdinaryRoom { episodes.append(ep); changed = true }
            else { remaining.append(item) }
        }
        pendingAdditions = remaining
        if changed { save() }
    }

    func pruneRollingEntries(windows: [String: Set<String>]) {
        let oldCount = episodes.count
        episodes.removeAll { episode in
            guard let feed = episode.rollingFeed, let window = windows[feed] else { return false }
            return !window.contains(episode.guid)
        }
        if episodes.count != oldCount { save() }
    }

    func releaseRollingEntries(feed: String) {
        let entries = episodes.filter { $0.rollingFeed == feed }
        guard !entries.isEmpty else { return }
        for entry in entries { entry.rollingFeed = nil }
        save()
    }

    func remove(guid: String) {
        removePending(guid: guid)
        episodes.removeAll { $0.guid == guid }
        save()
        refillLater()
    }

    func remove(at index: Int) {
        guard index >= 0, index < episodes.count else { return }
        episodes.remove(at: index)
        save()
        refillLater()
    }

    func move(from: Int, to: Int) {
        guard from != to,
              from >= 0, from < episodes.count,
              to >= 0, to < episodes.count else { return }
        let ep = episodes.remove(at: from)
        episodes.insert(ep, at: to)
        save()
    }

    // Pops the head. Called by AudioPlayer when an episode finishes.
    func next() -> Episode? {
        guard !episodes.isEmpty else { return nil }
        let ep = episodes.removeFirst()
        save()
        refillLater()
        return ep
    }

    private func refillLater() {
        // The player must claim the popped episode before pending arrivals refill.
        DispatchQueue.main.async { self.fillAvailableSlots() }
    }
}

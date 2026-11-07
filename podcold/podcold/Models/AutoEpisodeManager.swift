import UIKit

// Feed refreshes use the existing serial feed lane. State and decisions run on the main thread.
class AutoEpisodeManager {
    static let shared = AutoEpisodeManager()
    static let queueKey = "auto_queue_new_episodes"
    static let downloadKey = "auto_download_new_episodes"
    static let limitKey = "auto_download_limit"
    static let stateKey = "auto_episode_state_v1"
    static let limitRange = 1...20
    static let rollingLimitRange = 1...200

    static var queueEnabled: Bool {
        get { return UserDefaults.standard.object(forKey: queueKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: queueKey) }
    }
    static var downloadEnabled: Bool {
        get { return UserDefaults.standard.object(forKey: downloadKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: downloadKey) }
    }
    static var downloadLimit: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: limitKey)
            return limitRange.contains(value) ? value : 3
        }
        set { UserDefaults.standard.set(min(20, max(1, newValue)), forKey: limitKey) }
    }

    private var downloading = false
    private var refreshTimer: Timer?
    private var ready = false
    private var suspended = false

    private init() {
        NotificationCenter.default.addObserver(self, selector: #selector(reconcile), name: .episodeLibraryChanged, object: nil)
    }

    private var state: [String: Any] {
        get { return UserDefaults.standard.dictionary(forKey: AutoEpisodeManager.stateKey) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: AutoEpisodeManager.stateKey) }
    }

    static func rollingLimit(for feed: String) -> Int? {
        let raw = UserDefaults.standard.dictionary(forKey: stateKey)
        guard let limit = (raw?["rollingLimits"] as? [String: Int])?[feed], rollingLimitRange.contains(limit) else { return nil }
        return limit
    }

    func setRollingLimit(_ limit: Int?, for feed: String) {
        if let limit = limit, !Self.rollingLimitRange.contains(limit) { return }
        guard Self.rollingLimit(for: feed) != limit else { return }
        var raw = state
        var limits = raw["rollingLimits"] as? [String: Int] ?? [:]
        limits[feed] = limit
        raw["rollingLimits"] = limits
        var windows = raw["rollingItems"] as? [String: [[String: Any]]] ?? [:]
        if let limit = limit, let items = windows[feed] {
            windows[feed] = Array(items.prefix(limit))
        } else if limit == nil {
            windows[feed] = nil
            PlayQueue.shared.releaseRollingEntries(feed: feed)
        }
        raw["rollingItems"] = windows
        state = raw
        LatestEpisodeCache.remove(feedUrl: feed)
        refresh()
    }

    // State is deliberately independent of the expiring home-screen cache. Clearing
    // that cache, opening a feed again, and relaunching cannot enqueue duplicates.
    func observe(feedURL: String, episodes: [Episode]) {
        guard !suspended, !episodes.isEmpty, Podcast.isSubscribed(feedUrl: feedURL),
              Self.rollingLimit(for: feedURL) == nil else { return }
        var raw = state
        var seenByFeed = raw["seen"] as? [String: [String]] ?? [:]
        let previous = seenByFeed[feedURL]
        let known = Set(previous ?? [])
        let window = previous == nil ? Array(episodes.prefix(UpNextManager.maxNewEpisodes)) : episodes
        let current = AudioPlayer.shared.currentEpisode?.guid
        let candidates = window.reversed().filter {
            !known.contains($0.guid) && !Episode.isPlayed(guid: $0.guid) && $0.guid != current && !$0.audioUrl.isEmpty
        }
        // A bounded identity history per feed also tolerates temporarily shortened
        // feeds without treating reappearing entries as new on the next refresh.
        var history = previous ?? []
        var historySet = Set(history)
        for ep in episodes.reversed() where historySet.insert(ep.guid).inserted { history.append(ep.guid) }
        seenByFeed[feedURL] = Array(history.suffix(2000))
        raw["seen"] = seenByFeed
        var items = raw["items"] as? [[String: Any]] ?? []
        var pendingIDs = Set(items.compactMap { ($0["episode"] as? [String: Any])?["guid"] as? String })
        for ep in candidates {
            PlayQueue.shared.offerAutomatically(ep, source: .newEpisode)
            if AutoEpisodeManager.downloadEnabled && pendingIDs.insert(ep.guid).inserted {
                items.append(["feed": feedURL, "episode": ep.toDict(), "downloaded": false])
            }
        }
        raw["items"] = items
        state = raw
        reconcile()
    }

    func observeRolling(feedURL: String, episodes: [Episode], limit: Int) {
        guard !suspended, !episodes.isEmpty, Podcast.isSubscribed(feedUrl: feedURL),
              Self.rollingLimit(for: feedURL) == limit else { return }
        var raw = state
        var windows = raw["rollingItems"] as? [String: [[String: Any]]] ?? [:]
        var previous: [String: [String: Any]] = [:]
        for item in windows[feedURL] ?? [] {
            if let id = itemID(item) { previous[id] = item }
        }
        var ids = Set<String>()
        let unique = episodes.filter { !$0.audioUrl.isEmpty && ids.insert($0.guid).inserted }
        windows[feedURL] = unique.prefix(limit).map { episode in
            var item = previous[episode.guid] ?? [:]
            item["episode"] = episode.toDict()
            return item
        }
        raw["rollingItems"] = windows
        var seen = raw["seen"] as? [String: [String]] ?? [:]
        var history = seen[feedURL] ?? []
        var known = Set(history)
        history.append(contentsOf: unique.reversed().map { $0.guid }.filter { known.insert($0).inserted })
        seen[feedURL] = Array(history.suffix(2000))
        raw["seen"] = seen
        state = raw
        reconcile()
    }

    private func itemID(_ item: [String: Any]) -> String? {
        return (item["episode"] as? [String: Any])?["guid"] as? String
    }

    func downloadsReady() { ready = true; reconcile() }

    func becameActive() {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: 60, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        refresh()
    }

    func enteredBackground() { refreshTimer?.invalidate(); refreshTimer = nil }

    @objc private func refresh() {
        guard !suspended else { return }
        #if PODCOLD_DEVICE_TESTING
        if onlyTestInputs { reconcile(); return }
        #endif
        UpNextManager.shared.refreshStale(podcasts: Podcast.loadSubscriptions(), inProgressGuids: Set(Episode.loadRecents().filter { $0.savedPosition() > 30 }.map { $0.guid }))
        reconcile()
    }

    func settingsChanged() {
        PlayQueue.shared.fillAvailableSlots()
        // Changing the download switch/limit also applies to already observed
        // unplayed episodes in the playlist, without re-adding removed queue rows.
        if AutoEpisodeManager.downloadEnabled {
            var raw = state
            var items = raw["items"] as? [[String: Any]] ?? []
            var ids = Set(items.compactMap { ($0["episode"] as? [String: Any])?["guid"] as? String })
            for ep in PlayQueue.shared.episodes where !Episode.isPlayed(guid: ep.guid) && ids.insert(ep.guid).inserted {
                // Restrict automatic downloads to subscribed shows. The original
                // feed URL is recovered from its observed identity history.
                let seen = raw["seen"] as? [String: [String]] ?? [:]
                if let feed = seen.first(where: { $0.value.contains(ep.guid) })?.key, Self.rollingLimit(for: feed) == nil {
                    items.append(["feed": feed, "episode": ep.toDict(), "downloaded": false])
                }
            }
            raw["items"] = items; state = raw
        }
        refresh()
    }

    @objc func reconcile() {
        guard ready, !suspended, !downloading, UIApplication.shared.applicationState == .active else { return }
        var raw = state
        let subscriptions = Set(Podcast.loadSubscriptions().map { $0.feedUrl })
        var seen = raw["seen"] as? [String: [String]] ?? [:]
        seen = seen.filter { subscriptions.contains($0.key) }
        raw["seen"] = seen
        var items = (raw["items"] as? [[String: Any]] ?? []).filter {
            guard let feed = $0["feed"] as? String, let ep = $0["episode"] as? [String: Any], let guid = ep["guid"] as? String else { return false }
            return subscriptions.contains(feed) && Self.rollingLimit(for: feed) == nil && !Episode.isPlayed(guid: guid)
        }
        // Retain the success marker even if the user deletes the file: a manual
        // deletion must not be silently reversed by the next refresh.
        raw["items"] = items; state = raw
        if reconcileRolling(subscriptions: subscriptions) { return }
        guard AutoEpisodeManager.downloadEnabled else { return }
        let occupied = items.filter {
            ($0["downloaded"] as? Bool ?? false) && Episode.from(dict: $0["episode"] as? [String: Any] ?? [:]).localPath() != nil
        }.count
        guard occupied < AutoEpisodeManager.downloadLimit else { return }
        let now = Date().timeIntervalSince1970
        guard let index = items.firstIndex(where: {
            !($0["downloaded"] as? Bool ?? false) && ($0["retryAfter"] as? Double ?? 0) <= now
        }) else { return }
        let episode = Episode.from(dict: items[index]["episode"] as? [String: Any] ?? [:])
        if episode.localPath() != nil {
            // Already manually downloaded; it neither consumes an automatic slot
            // nor needs to be downloaded again.
            items.remove(at: index); raw["items"] = items; state = raw
            reconcile(); return
        }
        download(episode, rollingFeed: nil)
    }

    private func reconcileRolling(subscriptions: Set<String>) -> Bool {
        var raw = state
        let previous = raw["rollingItems"] as? [String: [[String: Any]]] ?? [:]
        var windows = previous.filter { subscriptions.contains($0.key) && Self.rollingLimit(for: $0.key) != nil }
        guard !previous.isEmpty else { return false }
        let ids = windows.mapValues { Set($0.compactMap(itemID)) }
        let playing = AudioPlayer.shared.currentEpisode?.guid
        if Self.queueEnabled || PlayQueue.addDownloads { PlayQueue.shared.pruneRollingEntries(windows: ids) }
        if Self.downloadEnabled { Episode.pruneRollingDownloads(windows: ids, playing: playing) }

        let now = Date().timeIntervalSince1970
        let playedIDs = Set(UserDefaults.standard.stringArray(forKey: Episode.playedGuidsKey) ?? [])
        var candidate: (Episode, String)?
        for feed in windows.keys.sorted() {
            guard var items = windows[feed] else { continue }
            for index in items.indices.reversed() {
                guard let record = items[index]["episode"] as? [String: Any] else { continue }
                let episode = Episode.from(dict: record)
                let played = playedIDs.contains(episode.guid)
                let needsQueue = !played && episode.guid != playing && items[index]["queued"] as? Bool != true
                let downloadPending = items[index]["downloaded"] as? Bool != true
                let queueOnDownload = needsQueue && !Self.queueEnabled && PlayQueue.addDownloads
                let hasFile = (downloadPending || queueOnDownload) && episode.localPath() != nil
                if hasFile { items[index]["downloaded"] = true }
                if needsQueue {
                    if Self.queueEnabled {
                        PlayQueue.shared.offerAutomatically(episode, source: .newEpisode, rollingFeed: feed)
                        items[index]["queued"] = true
                    } else if PlayQueue.addDownloads, hasFile {
                        PlayQueue.shared.offerAutomatically(episode, source: .download, rollingFeed: feed)
                        items[index]["queued"] = true
                    }
                }
                if candidate == nil, Self.downloadEnabled, episode.guid != playing,
                   !(played && Episode.autoDeleteFinished), items[index]["downloaded"] as? Bool != true,
                   (items[index]["retryAfter"] as? Double ?? 0) <= now {
                    candidate = (episode, feed)
                }
            }
            windows[feed] = items
        }
        raw["rollingItems"] = windows
        state = raw
        guard let (episode, feed) = candidate else { return false }
        download(episode, rollingFeed: feed)
        return true
    }

    private func download(_ episode: Episode, rollingFeed: String?) {
        downloading = true
        EpisodeDownloader.download(episode: episode, rollingFeed: rollingFeed, progress: { _ in }) { [weak self] success in
            guard let self = self else { return }
            self.downloading = false
            var updated = self.state
            func mark(_ items: inout [[String: Any]]) {
                guard let slot = items.firstIndex(where: { self.itemID($0) == episode.guid }) else { return }
                if success { items[slot]["downloaded"] = true }
                else { items[slot]["retryAfter"] = Date().timeIntervalSince1970 + 15 * 60 }
            }
            if let feed = rollingFeed {
                var windows = updated["rollingItems"] as? [String: [[String: Any]]] ?? [:]
                if var items = windows[feed] {
                    mark(&items)
                    windows[feed] = items
                }
                updated["rollingItems"] = windows
            } else {
                var items = updated["items"] as? [[String: Any]] ?? []
                mark(&items)
                updated["items"] = items
            }
            self.state = updated
            self.reconcile()
        }
    }

    #if PODCOLD_DEVICE_TESTING
    var onlyTestInputs = false
    func suspendForTest(_ value: Bool) { suspended = value }
    var isDownloadingForTest: Bool { return downloading }
    #endif
}

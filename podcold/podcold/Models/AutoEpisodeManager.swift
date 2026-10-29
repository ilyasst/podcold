import UIKit

// Feed refreshes hand us their existing first page; no extra network lane or
// feed request is needed. All state and decisions run on the main thread.
class AutoEpisodeManager {
    static let shared = AutoEpisodeManager()
    static let queueKey = "auto_queue_new_episodes"
    static let downloadKey = "auto_download_new_episodes"
    static let limitKey = "auto_download_limit"
    static let stateKey = "auto_episode_state_v1"
    static let limitRange = 1...20

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

    // State is deliberately independent of the expiring home-screen cache. Clearing
    // that cache, opening a feed again, and relaunching cannot enqueue duplicates.
    func observe(feedURL: String, episodes: [Episode]) {
        guard !suspended, !episodes.isEmpty, Podcast.isSubscribed(feedUrl: feedURL) else { return }
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
                if let feed = seen.first(where: { $0.value.contains(ep.guid) })?.key {
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
            return subscriptions.contains(feed) && !Episode.isPlayed(guid: guid)
        }
        // Retain the success marker even if the user deletes the file: a manual
        // deletion must not be silently reversed by the next refresh.
        raw["items"] = items; state = raw
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
        downloading = true
        EpisodeDownloader.download(episode: episode, progress: { _ in }) { [weak self] success in
            guard let self = self else { return }
            self.downloading = false
            var updated = self.state
            var remaining = updated["items"] as? [[String: Any]] ?? []
            if let slot = remaining.firstIndex(where: { ($0["episode"] as? [String: Any])?["guid"] as? String == episode.guid }) {
                if success { remaining[slot]["downloaded"] = true }
                else { remaining[slot]["retryAfter"] = Date().timeIntervalSince1970 + 15 * 60 }
            }
            updated["items"] = remaining; self.state = updated
            self.reconcile()
        }
    }

    #if PODCOLD_DEVICE_TESTING
    var onlyTestInputs = false
    func suspendForTest(_ value: Bool) { suspended = value }
    var isDownloadingForTest: Bool { return downloading }
    #endif
}

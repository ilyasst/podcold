#if PODCOLD_DEVICE_TESTING
import UIKit

enum DeviceFeedTest {
    private static var navigation: UINavigationController?
    private static var original: [Podcast]?
    private static var checks: [String: Any] = [:]
    private static var feedURL = ""
    private static var attempts = 0
    private static var savedCount = 0

    private static func views(_ root: UIView) -> [UIView] {
        return [root] + root.subviews.flatMap { views($0) }
    }

    static func run(navigation: UINavigationController) {
        self.navigation = navigation
        original = Podcast.loadSubscriptions()
        checks = [:]
        for arg in CommandLine.arguments {
            for (prefix, key) in [("--podcold-test-token=", "run_token"), ("--podcold-feed-url=", "url")] {
                if arg.hasPrefix(prefix) {
                    let value = String(arg.dropFirst(prefix.count))
                    if key == "url" { feedURL = value } else { checks[key] = value }
                }
            }
        }
        let fixtures = fixtureChecks()
        checks["feed_fixtures"] = fixtures
        checks["feed_validation"] = fixtures.values.allSatisfy { $0 }
        guard Podcast.normalizedFeedURL(feedURL) != nil else { finish("No valid test feed URL"); return }
        guard let home = navigation.topViewController as? HomeVC,
              let item = home.navigationItem.rightBarButtonItems?.first(where: {
                  $0.action.map { NSStringFromSelector($0) == "openSearch" } ?? false
              }), let action = item.action else { finish("Home search button missing"); return }
        UIApplication.shared.sendAction(action, to: item.target, from: item, for: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { openForm() }
    }

    private static func openForm() {
        guard let search = navigation?.topViewController as? SearchVC,
              let item = search.navigationItem.rightBarButtonItem,
              let action = item.action else { finish("Add URL button missing"); return }
        UIApplication.shared.sendAction(action, to: item.target, from: item, for: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { enterURL() }
    }

    private static func enterURL() {
        guard let form = navigation?.topViewController as? AddFeedVC,
              let field = views(form.view).first(where: { $0.accessibilityIdentifier == "feed-url" }) as? UITextField,
              let button = views(form.view).first(where: { $0.accessibilityIdentifier == "add-feed" }) as? UIButton,
              let status = views(form.view).first(where: { $0.accessibilityIdentifier == "feed-status" }) as? UILabel,
              let window = field.window, let navigation = navigation else {
            finish("Feed URL controls missing"); return
        }
        let frame = field.convert(field.bounds, to: window)
        let bar = navigation.navigationBar.convert(navigation.navigationBar.bounds, to: window)
        checks["feed_url_visible"] = !field.isHidden && frame.minY >= bar.maxY && frame.width > 100
        checks["feed_url_keyboard"] = field.isFirstResponder
        field.text = "file:///not-a-feed"
        button.sendActions(for: .touchUpInside)
        checks["invalid_url_rejected"] = !(status.text ?? "").isEmpty &&
            Podcast.loadSubscriptions().count == original?.count
        // Exercise default HTTPS as well as the literal URL path.
        field.text = feedURL.hasPrefix("https://") ? String(feedURL.dropFirst(8)) : feedURL
        field.becomeFirstResponder()
        emit("feed_entry")
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            button.sendActions(for: .touchUpInside)
            attempts = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { inspectAdded() }
        }
    }

    private static func inspectAdded() {
        guard let navigation = navigation else { return }
        if let list = navigation.topViewController as? EpisodeListVC {
            checks["feed_saved"] = Podcast.subscription(feedUrl: feedURL) != nil
            checks["feed_title_loaded"] = !list.podcast.title.isEmpty && list.podcast.title != feedURL
            let table = views(list.view).compactMap { $0 as? UITableView }.first
            let count = table.flatMap { $0.dataSource?.tableView($0, numberOfRowsInSection: 0) } ?? 0
            if count > 0 {
                checks["feed_episode_count"] = count
                checks["feed_episodes_loaded"] = true
                savedCount = Podcast.loadSubscriptions().count
                navigation.pushViewController(AddFeedVC(), animated: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { checkDuplicate() }
                return
            }
        } else if let form = navigation.topViewController as? AddFeedVC,
                  let button = views(form.view).first(where: { $0.accessibilityIdentifier == "add-feed" }) as? UIButton,
                  let status = views(form.view).first(where: { $0.accessibilityIdentifier == "feed-status" }) as? UILabel,
                  button.isEnabled, let text = status.text, !text.isEmpty, text != "Checking feed..." {
            finish(text); return
        }
        attempts += 1
        if attempts >= 65 { finish("Feed did not open with episodes within 65 seconds"); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { inspectAdded() }
    }

    private static func checkDuplicate() {
        guard let form = navigation?.topViewController as? AddFeedVC,
              let field = views(form.view).first(where: { $0.accessibilityIdentifier == "feed-url" }) as? UITextField,
              let button = views(form.view).first(where: { $0.accessibilityIdentifier == "add-feed" }) as? UIButton else {
            finish("Duplicate-add controls missing"); return
        }
        field.text = feedURL + "#duplicate-test"
        button.sendActions(for: .touchUpInside)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            checks["duplicate_prevented"] = Podcast.loadSubscriptions().count == savedCount &&
                navigation?.topViewController is EpisodeListVC
            finish(nil)
        }
    }

    private static func fixtureChecks() -> [String: Bool] {
        let base = "https://example.invalid/feed.xml"
        func parse(_ xml: String) -> FeedParser.PodcastFeed? {
            return try? FeedParser.parsePodcast(data: Data(xml.utf8), feedUrl: base).get()
        }
        let rss = parse("<rss xmlns:itunes='http://www.itunes.com/dtds/podcast-1.0.dtd'><channel><title>Fixture &amp; Test</title><itunes:author>Author</itunes:author><itunes:image href='/cover.png'/><item><title>Episode One</title><guid>fixture-one</guid><enclosure url='/audio.mp3' type='audio/mpeg'/></item></channel></rss>")
        let atom = parse("<feed xmlns='http://www.w3.org/2005/Atom'><title>Atom Show</title><author><name>Atom Author</name></author><entry><id>atom-one</id><title>Atom Episode</title><link rel='enclosure' type='audio/mpeg' href='episode.mp3'/></entry></feed>")
        let item = "<item><title>Episode</title><enclosure url='https://example.invalid/audio.mp3'/></item>"
        let paged = parse("<rss><channel><title>Many Episodes</title>" + String(repeating: item, count: 21) + "</channel></rss>")
        return [
            "rss_metadata": rss?.podcast.title == "Fixture & Test" && rss?.podcast.author == "Author",
            "rss_episodes": rss?.episodes.first?.title == "Episode One" && rss?.episodes.first?.podcastTitle == "Fixture & Test",
            "relative_urls": rss?.podcast.artworkUrl == "https://example.invalid/cover.png" && rss?.episodes.first?.audioUrl == "https://example.invalid/audio.mp3",
            "atom": atom?.podcast.author == "Atom Author" && atom?.episodes.first?.audioUrl == "https://example.invalid/episode.mp3",
            "empty_feed": parse("<rss><channel><title>Empty Feed</title></channel></rss>")?.episodes.isEmpty == true,
            "webpage_rejected": parse("<html><head><title>Website</title></head><body>Not RSS</body></html>") == nil,
            "malformed_rejected": parse("<rss><channel><title>Broken</title><item>") == nil,
            "non_audio_rejected": parse("<rss><channel><title>News</title><item><title>Article</title></item></channel></rss>") == nil,
            "first_page_limit": paged?.episodes.count == FeedParser.pageSize,
            "url_normalization": Podcast.normalizedFeedURL(" HTTPS://EXAMPLE.invalid:443/feed.xml?token=test#x ") == "https://example.invalid/feed.xml?token=test",
            "invalid_schemes": Podcast.normalizedFeedURL("ftp://example.invalid/rss") == nil && Podcast.normalizedFeedURL("file:///tmp/feed.xml") == nil
        ]
    }

    private static func finish(_ error: String?) {
        if let subscriptions = original {
            Podcast.saveSubscriptions(subscriptions)
            UserDefaults.standard.synchronize()
            checks["subscriptions_restored"] = Podcast.loadSubscriptions().map { $0.feedUrl } == subscriptions.map { $0.feedUrl }
            original = nil
        }
        let required = ["feed_validation", "feed_url_visible", "feed_url_keyboard", "invalid_url_rejected",
                        "feed_saved", "feed_title_loaded", "feed_episodes_loaded", "duplicate_prevented", "subscriptions_restored"]
        checks["passed"] = error == nil && required.allSatisfy { checks[$0] as? Bool == true }
        if let error = error { checks["error"] = error }
        emit("complete")
        navigation = nil
    }

    private static func emit(_ stage: String) {
        var report = checks
        report["stage"] = stage
        if let data = try? JSONSerialization.data(withJSONObject: report, options: []),
           let text = String(data: data, encoding: .utf8) { NSLog("PODCOLD_DEVICE_TEST %@", text) }
    }
}
#endif

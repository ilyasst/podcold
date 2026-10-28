import Foundation

class FeedParser: NSObject, XMLParserDelegate {
    private var episodes: [Episode] = []
    private var channelArtwork = ""
    fileprivate var podcastTitle = ""
    private var currentEpisode: Episode?
    private var currentText = ""
    private var inItem = false          // RSS <item> or Atom <entry>
    private var elementPath: [String] = []
    private var sawChannel = false
    private var feedTitle = ""
    private var feedAuthor = ""
    private var itemCount = 0
    private var stoppedAtLimit = false

    private var limit = FeedParser.pageSize
    private static let parseQueue = DispatchQueue(label: "com.podcold.feedparser")

    // MARK: — Public entry point

    // A feed is a single XML document with no server-side paging, so "load more"
    // means parsing further into the same bytes. Parsing stops at `limit` via
    // abortParsing(), so a deeper re-parse only reads as far as it needs to.
    static let pageSize = 20

    struct PodcastFeed {
        let podcast: Podcast
        let episodes: [Episode]
    }

    static func loadPodcast(feedUrl: String, completion: @escaping (Result<PodcastFeed, Error>) -> Void) {
        CurlFetcher.fetchFeed(url: feedUrl) { data in
            guard let data = data else {
                completion(.failure(feedError("Could not download the feed. Check the link and your connection.")))
                return
            }
            parseQueue.async {
                let result = parsePodcast(data: data, feedUrl: feedUrl)
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    static func parsePodcast(data: Data, feedUrl: String) -> Result<PodcastFeed, Error> {
        let p = FeedParser()
        let xml = XMLParser(data: data)
        xml.shouldResolveExternalEntities = false
        xml.delegate = p
        let validXML = xml.parse() || p.stoppedAtLimit
        guard validXML, p.sawChannel, !p.feedTitle.isEmpty else {
            return .failure(feedError("This link is not a valid RSS or Atom feed. Use the podcast's RSS link, not its website."))
        }
        guard p.itemCount == 0 || !p.episodes.isEmpty else {
            return .failure(feedError("This feed does not contain playable audio episodes."))
        }
        let podcast = Podcast()
        podcast.feedUrl = feedUrl
        podcast.title = p.feedTitle
        podcast.author = p.feedAuthor
        podcast.artworkUrl = absolute(p.channelArtwork, relativeTo: feedUrl)
        podcast.artworkUrl600 = podcast.artworkUrl
        podcast.episodeCount = p.episodes.count
        for episode in p.episodes {
            episode.podcastTitle = podcast.title
            episode.audioUrl = absolute(episode.audioUrl, relativeTo: feedUrl)
            episode.artworkUrl = absolute(episode.artworkUrl, relativeTo: feedUrl)
        }
        return .success(PodcastFeed(podcast: podcast, episodes: p.episodes))
    }

    private static func absolute(_ value: String, relativeTo feed: String) -> String {
        guard !value.isEmpty else { return "" }
        return URL(string: value, relativeTo: URL(string: feed))?.absoluteURL.absoluteString ?? value
    }

    private static func feedError(_ message: String) -> NSError {
        return NSError(domain: "Podcold.Feed", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func parse(feedUrl: String, podcastTitle: String, limit: Int = pageSize,
                      completion: @escaping ([Episode]) -> Void) {
        parseKeepingData(feedUrl: feedUrl, podcastTitle: podcastTitle, limit: limit) { eps, _ in
            completion(eps)
        }
    }

    // Re-parse bytes the caller already holds — no network. Used by
    // EpisodeListVC's load-more.
    static func parse(data: Data, podcastTitle: String, limit: Int, feedUrl: String? = nil,
                      completion: @escaping ([Episode]) -> Void) {
        parseQueue.async {
            let eps = runXML(data: data, podcastTitle: podcastTitle, limit: limit)
            if let url = feedUrl { resolveURLs(eps, feedUrl: url) }
            DispatchQueue.main.async { completion(eps) }
        }
    }

    // As `parse`, but also hands back the raw feed bytes so the caller can page
    // deeper without a second download.
    static func parseKeepingData(feedUrl: String, podcastTitle: String, limit: Int = pageSize,
                                 completion: @escaping ([Episode], Data?) -> Void) {
        // Use CurlFetcher (libcurl + OpenSSL) — handles GCM ciphers that NSURLConnection
        // (Apple Secure Transport) cannot negotiate on iOS 6.
        //
        // HTTP is a *sequential fallback*, not a parallel race: the feed lane is a
        // serial queue, so firing both at once did not race — the loser still
        // downloaded the entire feed and threw it away, doubling traffic on every
        // refresh. Only try plain HTTP once HTTPS has actually failed.
        let httpFallback: String? = feedUrl.lowercased().hasPrefix("https://")
            ? "http://" + String(feedUrl.dropFirst(8))
            : nil

        // No wall-clock watchdog here: it measured from enqueue rather than from
        // request start, so a busy lane made it fire while the request was still
        // queued — reporting failure and then discarding the real response.
        // CURLOPT_TIMEOUT guarantees curl always calls back.
        func finish(_ data: Data?) {
            guard let data = data else { completion([], nil); return }
            FeedParser.parseQueue.async {
                let eps = FeedParser.runXML(data: data, podcastTitle: podcastTitle, limit: limit)
                resolveURLs(eps, feedUrl: feedUrl)
                DispatchQueue.main.async { completion(eps, data) }
            }
        }

        CurlFetcher.fetchFeed(url: feedUrl) { data in
            if data != nil { finish(data); return }
            guard let http = httpFallback else { finish(nil); return }
            CurlFetcher.fetchFeed(url: http) { fallbackData in finish(fallbackData) }
        }
    }

    // MARK: — Synchronous XML parse

    private static func resolveURLs(_ episodes: [Episode], feedUrl: String) {
        for episode in episodes {
            episode.audioUrl = absolute(episode.audioUrl, relativeTo: feedUrl)
            episode.artworkUrl = absolute(episode.artworkUrl, relativeTo: feedUrl)
        }
    }

    private static func runXML(data: Data, podcastTitle: String, limit: Int) -> [Episode] {
        let p = FeedParser()
        p.podcastTitle = podcastTitle
        p.limit = limit
        let xml = XMLParser(data: data)
        xml.delegate = p
        xml.parse()
        return p.episodes
    }

    // MARK: — XMLParserDelegate

    func parserDidStartDocument(_ parser: XMLParser) { episodes = [] }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes: [String: String] = [:]) {
        elementPath.append(elementName)
        if elementPath == ["rss", "channel"] || elementPath == ["feed"] { sawChannel = true }
        currentText = ""
        switch elementName {

        case "item", "entry":
            itemCount += 1
            inItem = true
            currentEpisode = Episode()
            currentEpisode?.podcastTitle = podcastTitle

        case "enclosure" where inItem:
            if let url = attributes["url"], !url.isEmpty {
                currentEpisode?.audioUrl = url
            }

        case "media:content" where inItem:
            if let url = attributes["url"], !url.isEmpty,
               currentEpisode?.audioUrl.isEmpty == true {
                let mime = attributes["type"] ?? ""
                if mime.hasPrefix("audio") || mime.isEmpty {
                    currentEpisode?.audioUrl = url
                }
            }

        case "link" where inItem:
            if attributes["rel"] == "enclosure",
               let href = attributes["href"], !href.isEmpty,
               currentEpisode?.audioUrl.isEmpty == true {
                currentEpisode?.audioUrl = href
            }

        case "itunes:image" where !inItem:
            channelArtwork = attributes["href"] ?? ""
        case "itunes:image" where inItem:
            if let href = attributes["href"], !href.isEmpty {
                currentEpisode?.artworkUrl = href
            }

        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        defer { elementPath.removeLast() }
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        if !inItem {
            if elementPath == ["rss", "channel", "title"] || elementPath == ["feed", "title"] {
                feedTitle = text
            } else if elementPath == ["rss", "channel", "itunes:author"] ||
                        elementPath == ["feed", "author", "name"] {
                feedAuthor = text
            } else if elementPath == ["rss", "channel", "image", "url"] && channelArtwork.isEmpty {
                channelArtwork = text
            } else if elementPath == ["feed", "logo"] && channelArtwork.isEmpty {
                channelArtwork = text
            }
        }

        if elementName == "item" || elementName == "entry" {
            if let ep = currentEpisode, !ep.audioUrl.isEmpty {
                if ep.artworkUrl.isEmpty { ep.artworkUrl = channelArtwork }
                // <guid> is optional in RSS 2.0 — without a substitute every
                // guid-less episode in the feed collides on one download path
                // and one saved position. See Episode.ensureGuid().
                ep.ensureGuid()
                episodes.append(ep)
            }
            inItem = false; currentEpisode = nil
            // RSS/Atom feeds are newest-first — abort as soon as we have enough
            if episodes.count >= limit {
                stoppedAtLimit = true
                parser.abortParsing()
            }
            return
        }

        guard inItem else { return }

        switch elementName {
        case "title":
            currentEpisode?.title = text
        case "guid", "id":
            currentEpisode?.guid = text
        case "pubDate", "published", "updated":
            if currentEpisode?.pubDate.isEmpty == true { currentEpisode?.pubDate = text }
        case "itunes:duration":
            currentEpisode?.duration = text
        // First one wins. A `where` on a multi-pattern case only guards the last
        // pattern, so "content" used to clobber an already-parsed summary.
        case "itunes:summary", "description", "content", "content:encoded":
            if currentEpisode?.summary.isEmpty == true { currentEpisode?.summary = text }
        default: break
        }
    }

    func parserDidEndDocument(_ parser: XMLParser) {}
}

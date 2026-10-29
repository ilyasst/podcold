import Foundation

class Podcast: NSObject {
    var collectionId: Int = 0
    var title: String = ""
    var author: String = ""
    var feedUrl: String = ""
    var artworkUrl: String = ""
    var artworkUrl600: String = ""
    var genre: String = ""
    var episodeCount: Int = 0

    static let subscriptionsKey = "subscribed_podcasts"

    static func loadSubscriptions() -> [Podcast] {
        guard let arr = UserDefaults.standard.array(forKey: subscriptionsKey) as? [[String: Any]] else { return [] }
        return arr.map { Podcast.from(dict: $0) }
    }

    static func saveSubscriptions(_ podcasts: [Podcast]) {
        UserDefaults.standard.set(podcasts.map { $0.toDict() }, forKey: subscriptionsKey)
    }

    static func normalizedFeedURL(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", let host = url.host, !host.isEmpty,
              let separator = text.range(of: "://") else { return nil }
        // NSURLComponents first appeared in iOS 7. Normalize the authority using
        // NSURL's parsed host/port while keeping escaped path and query bytes.
        let tail = String(text[separator.upperBound...]).components(separatedBy: "#")[0]
        let boundary = tail.firstIndex(where: { $0 == "/" || $0 == "?" }) ?? tail.endIndex
        let authority = String(tail[..<boundary])
        let credentials = authority.lastIndex(of: "@").map { String(authority[...$0]) } ?? ""
        let normalizedHost = host.contains(":") && !host.hasPrefix("[") ? "[" + host.lowercased() + "]" : host.lowercased()
        let port = url.port
        let defaultPort = (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
        let suffix = port != nil && !defaultPort ? ":" + String(port!) : ""
        return scheme + "://" + credentials + normalizedHost + suffix + String(tail[boundary...])
    }

    static func subscription(feedUrl: String) -> Podcast? {
        let key = normalizedFeedURL(feedUrl) ?? feedUrl
        return loadSubscriptions().first { (normalizedFeedURL($0.feedUrl) ?? $0.feedUrl) == key }
    }

    // Recheck at save time too, so asynchronous validation cannot add duplicates.
    @discardableResult
    static func subscribe(_ podcast: Podcast) -> Podcast {
        if let existing = subscription(feedUrl: podcast.feedUrl) { return existing }
        var subscriptions = loadSubscriptions()
        subscriptions.append(podcast)
        saveSubscriptions(subscriptions)
        return podcast
    }

    static func isSubscribed(feedUrl: String) -> Bool {
        guard let arr = UserDefaults.standard.array(forKey: subscriptionsKey) as? [[String: Any]] else { return false }
        return arr.contains { ($0["feedUrl"] as? String) == feedUrl }
    }

    func toDict() -> [String: Any] {
        return ["collectionId": collectionId, "title": title, "author": author,
                "feedUrl": feedUrl, "artworkUrl": artworkUrl, "artworkUrl600": artworkUrl600, "genre": genre]
    }

    static func from(dict: [String: Any]) -> Podcast {
        let p = Podcast()
        p.collectionId = dict["collectionId"] as? Int ?? 0
        p.title        = dict["title"]        as? String ?? ""
        p.author       = dict["author"]       as? String ?? ""
        p.feedUrl      = dict["feedUrl"]      as? String ?? ""
        p.artworkUrl   = dict["artworkUrl"]   as? String ?? ""
        p.artworkUrl600 = dict["artworkUrl600"] as? String ?? ""
        p.genre        = dict["genre"]        as? String ?? ""
        return p
    }
}

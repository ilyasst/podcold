import Foundation

class HTTPClient {

    static func get(url: String, headers: [String: String] = [:], validateServerTrust: Bool = false, completion: @escaping (Data?, Error?) -> Void) {
        guard let nsUrl = URL(string: url) else {
            completion(nil, makeError("Invalid URL: \(url)")); return
        }
        var req = URLRequest(url: nsUrl)
        req.httpMethod = "GET"
        req.timeoutInterval = 30
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        send(req, validateServerTrust: validateServerTrust, completion: completion)
    }

    static func post(url: String, headers: [String: String] = [:], body: [String: Any], validateServerTrust: Bool = false, completion: @escaping (Data?, Error?) -> Void) {
        guard let nsUrl = URL(string: url) else {
            completion(nil, makeError("Invalid URL: \(url)")); return
        }
        var req = URLRequest(url: nsUrl)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let data = try? JSONSerialization.data(withJSONObject: body) { req.httpBody = data }
        send(req, validateServerTrust: validateServerTrust, completion: completion)
    }

    // Always use NSURLFetcher — works iOS 6 through iOS 15+
    // (NSURLConnection is deprecated from iOS 9 but never removed)
    private static func send(_ req: URLRequest, validateServerTrust: Bool, completion: @escaping (Data?, Error?) -> Void) {
        if Thread.isMainThread {
            NSURLFetcher.fetch(req, validateServerTrust: validateServerTrust, completion: completion)
        } else {
            DispatchQueue.main.async { NSURLFetcher.fetch(req, validateServerTrust: validateServerTrust, completion: completion) }
        }
    }

    static func makeError(_ msg: String) -> NSError {
        NSError(domain: "HTTPClient", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}

// NSURLConnection delegate wrapper — static array keeps instances alive (same as EpisodeDownloader).
// Timer runs in .common mode so it fires in UITrackingRunLoopMode (UISearchBar active) too.
private class NSURLFetcher: NSObject, NSURLConnectionDataDelegate {
    private var accumulated = Data()
    private let completion: (Data?, Error?) -> Void
    private var conn: NSURLConnection?
    private var timer: Timer?
    private var finished = false
    private var validateServerTrust = false
    private var responseCode = 0
    private static var active: [NSURLFetcher] = []

    static func fetch(_ request: URLRequest, validateServerTrust: Bool, completion: @escaping (Data?, Error?) -> Void) {
        let f = NSURLFetcher(completion: completion)
        f.validateServerTrust = validateServerTrust
        active.append(f)

        // Schedule in .common so it fires in both default and UITracking run loop modes
        let t = Timer(timeInterval: 30, target: f, selector: #selector(NSURLFetcher.timedOut),
                      userInfo: nil, repeats: false)
        RunLoop.main.add(t, forMode: .common)
        f.timer = t

        // Schedule connection on main run loop in .common mode
        let c = NSURLConnection(request: request, delegate: f, startImmediately: false)
        c?.schedule(in: .main, forMode: .common)
        c?.start()
        f.conn = c
    }

    private init(completion: @escaping (Data?, Error?) -> Void) { self.completion = completion }

    @objc private func timedOut() { finish(nil, HTTPClient.makeError("Timeout")) }

    func connection(_ c: NSURLConnection, didReceive response: URLResponse) {
        accumulated = Data()
        responseCode = (response as? HTTPURLResponse)?.statusCode ?? 0
    }
    func connection(_ c: NSURLConnection, didReceive d: Data) { accumulated.append(d) }
    func connectionDidFinishLoading(_ c: NSURLConnection) {
        if (200...299).contains(responseCode) {
            finish(accumulated, nil)
        } else {
            finish(nil, NSError(domain: "HTTPClient", code: responseCode,
                                userInfo: [NSLocalizedDescriptionKey: "HTTP \(responseCode)"]))
        }
    }
    func connection(_ c: NSURLConnection, didFailWithError e: Error) { finish(nil, e) }

    // Explicit redirect — returning the request ensures iOS 6 calls our auth challenge
    // delegate methods for the redirect-target's TLS connection.
    func connection(_ c: NSURLConnection, willSend request: URLRequest,
                    redirectResponse: URLResponse?) -> URLRequest? {
        if validateServerTrust, let previous = redirectResponse?.url, let next = request.url,
           previous.scheme != next.scheme || previous.host != next.host || previous.port != next.port {
            finish(nil, HTTPClient.makeError("The server redirected to a different origin."))
            return nil
        }
        return request
    }

    // SSL bypass — both old-style and new-style.
    // On iOS 6, redirect-leg TLS connections may invoke old-style methods instead of
    // willSendRequestFor:. Implementing all three ensures bypass works in every case.

    func connection(_ c: NSURLConnection, willSendRequestFor challenge: URLAuthenticationChallenge) {
        sslBypass(challenge)
    }

    func connection(_ c: NSURLConnection, canAuthenticateAgainstProtectionSpace
                    space: URLProtectionSpace) -> Bool {
        return !validateServerTrust && space.authenticationMethod == NSURLAuthenticationMethodServerTrust
    }

    func connection(_ c: NSURLConnection,
                    didReceive challenge: URLAuthenticationChallenge) {
        sslBypass(challenge)
    }

    private func sslBypass(_ challenge: URLAuthenticationChallenge) {
        guard let sender = challenge.sender else { return }
        if !validateServerTrust, challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            sender.use(URLCredential(trust: trust), for: challenge)
        } else {
            sender.performDefaultHandling?(for: challenge)
        }
    }

    // Single-entry. On timeout the connection was previously only dropped from
    // our strong reference, not cancelled — NSURLConnection retains its delegate
    // while scheduled, so it stayed alive and later called
    // connectionDidFinishLoading, invoking the caller's completion a second time.
    // All delegate callbacks funnel through here, so one guard covers them all.
    private func finish(_ data: Data?, _ error: Error?) {
        guard !finished else { return }
        finished = true
        timer?.invalidate(); timer = nil
        conn?.cancel(); conn = nil
        NSURLFetcher.active.removeAll { $0 === self }
        DispatchQueue.main.async { self.completion(data, error) }
    }
}

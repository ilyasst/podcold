import Foundation
#if canImport(UIKit)
import UIKit
#endif

class PlayerSyncClient {
    static let shared = PlayerSyncClient()
    private let bgQueue = DispatchQueue(label: "com.podcold.sync")
    private let pendingEventsKey = "paz_sync_pending_events"
    private var pendingEvents: [[String: Any]] = []
    private var isFlushing = false
    private var generation = 0
    private var lastRemoteOwner: String?
    #if canImport(UIKit)
    private var timer: Timer?
    #endif

    var apiUrl: String {
        get { return UserDefaults.standard.string(forKey: "paz_sync_url") ?? "" }
        set {
            var value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            while value.hasSuffix("/") { value.removeLast() }
            if !value.isEmpty && !value.hasSuffix("/api/player/v1") { value += "/api/player/v1" }
            UserDefaults.standard.set(value, forKey: "paz_sync_url")
        }
    }
    var deviceId: String? {
        get { return UserDefaults.standard.string(forKey: "paz_sync_device_id") }
        set { UserDefaults.standard.set(newValue, forKey: "paz_sync_device_id") }
    }
    var credential: String? {
        get { return UserDefaults.standard.string(forKey: "paz_sync_credential") }
        set { UserDefaults.standard.set(newValue, forKey: "paz_sync_credential") }
    }
    var revision: Int {
        get { return UserDefaults.standard.integer(forKey: "paz_sync_revision") }
        set { UserDefaults.standard.set(newValue, forKey: "paz_sync_revision") }
    }
    var sessionId: String? {
        get { return UserDefaults.standard.string(forKey: "paz_sync_session_id") }
        set { UserDefaults.standard.set(newValue, forKey: "paz_sync_session_id") }
    }
    var isConfigured: Bool { return !apiUrl.isEmpty && credential != nil && deviceId != nil }

    var httpClientPost: (String, [String: String], [String: Any], @escaping (Data?, Error?) -> Void) -> Void = { url, headers, body, completion in
        #if canImport(UIKit)
        HTTPClient.post(url: url, headers: headers, body: body, validateServerTrust: true, completion: completion)
        #else
        fatalError("Inject HTTPClient.post")
        #endif
    }
    var httpClientGet: (String, [String: String], @escaping (Data?, Error?) -> Void) -> Void = { url, headers, completion in
        #if canImport(UIKit)
        HTTPClient.get(url: url, headers: headers, validateServerTrust: true, completion: completion)
        #else
        fatalError("Inject HTTPClient.get")
        #endif
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: pendingEventsKey),
           let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            pendingEvents = list
        }
    }

    private func savePending() {
        if let data = try? JSONSerialization.data(withJSONObject: pendingEvents) {
            UserDefaults.standard.set(data, forKey: pendingEventsKey)
            UserDefaults.standard.synchronize()
        }
    }

    func disconnect() {
        credential = nil
        deviceId = nil
        sessionId = nil
        revision = 0
        bgQueue.async {
            self.generation += 1
            self.lastRemoteOwner = nil
            self.pendingEvents.removeAll()
            self.isFlushing = false
            self.savePending()
        }
    }

    func enroll(code: String, label: String, completion: @escaping (Bool, String?) -> Void) {
        guard let url = URL(string: apiUrl), url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            completion(false, "Enter the Paz HTTPS server address.")
            return
        }
        httpClientPost(apiUrl + "/pair", [:], ["code": code, "label": label]) { data, error in
            guard error == nil, let data = data,
                  let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = result["device_id"] as? String, let token = result["credential"] as? String else {
                completion(false, error?.localizedDescription ?? "Invalid enrollment response")
                return
            }
            self.disconnect()
            self.deviceId = id
            self.credential = token
            #if canImport(UIKit)
            self.beginSyncing()
            for episode in PlayQueue.shared.episodes {
                var params: [String: Any] = ["episode_guid": episode.guid, "origin": episode.rollingFeed == nil ? "manual" : "automatic"]
                if let version = episode.audioVersion { params["audio_version"] = version }
                self.postEvent(type: "queue_add", params: params, immediate: true)
            }
            #endif
            completion(true, nil)
        }
    }

    func postEvent(type: String, params: [String: Any], immediate: Bool = false) {
        guard isConfigured else { return }
        bgQueue.async {
            var event = params
            event["event_id"] = UUID().uuidString
            event["type"] = type
            if type == "start" { event["base_revision"] = self.revision }
            if event["audio_version"] as? String == "" { event.removeValue(forKey: "audio_version") }
            if event["session_id"] as? String == "" { event.removeValue(forKey: "session_id") }
            self.pendingEvents.append(event)
            self.savePending()
            // A queue edit should reach another device while this screen is open.
            self.sendNext()
        }
    }

    func flushPending() { bgQueue.async { self.sendNext() } }

    private func sendNext() {
        guard isConfigured, let token = credential, !isFlushing, var event = pendingEvents.first,
              let id = event["event_id"] as? String, let type = event["type"] as? String else { return }
        let queueEdit = ["queue_add", "queue_remove", "queue_move"].contains(type)
        if queueEdit || (type == "start" && (lastRemoteOwner == nil || lastRemoteOwner == deviceId)) {
            event["base_revision"] = revision
        }
        if ["checkpoint", "pause", "seek", "complete", "queue_advance"].contains(type), event["session_id"] == nil {
            guard let ownSession = sessionId else {
                pendingEvents.removeFirst()
                savePending()
                sendNext()
                return
            }
            event["session_id"] = ownSession
            // Persist the exact identity sent so a retry cannot acquire a different session.
            pendingEvents[0] = event
            savePending()
        }
        let requestGeneration = generation
        isFlushing = true
        httpClientPost(apiUrl + "/events", ["Authorization": "Bearer " + token], event) { data, error in
            self.bgQueue.async {
                guard requestGeneration == self.generation else { return }
                self.isFlushing = false
                if let error = error as NSError?, error.domain == "HTTPClient", [400, 409, 422].contains(error.code) {
                    if ["start", "checkpoint", "pause", "seek", "complete", "queue_advance"].contains(type) {
                        self.discardPlaybackBatch()
                        self.sessionId = nil
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(name: NSNotification.Name("podcold.sync.conflict"), object: nil)
                        }
                    } else {
                        self.pendingEvents.removeFirst()
                    }
                    self.savePending()
                    self.fetchState { _ in self.flushPending() }
                    return
                }
                guard error == nil, let response = self.decodeState(data) else { return }
                self.acceptState(response)
                if response["conflict"] as? Bool == true {
                    if queueEdit {
                        // Rebase this independent edit on the returned revision.
                        if (event["base_revision"] as? Int ?? -1) != self.revision { self.sendNext() }
                        return
                    }
                    self.discardPlaybackBatch()
                    self.sessionId = nil
                    self.savePending()
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: NSNotification.Name("podcold.sync.conflict"), object: nil)
                    }
                } else if self.pendingEvents.first?["event_id"] as? String == id {
                    self.pendingEvents.removeFirst()
                    self.savePending()
                }
                self.sendNext()
            }
        }
    }

    private func discardPlaybackBatch() {
        var reachedNewStart = false
        pendingEvents = pendingEvents.enumerated().filter { offset, item in
            let kind = item["type"] as? String ?? ""
            if offset > 0 && kind == "start" { reachedNewStart = true }
            return reachedNewStart || !["start", "checkpoint", "pause", "seek", "complete", "queue_advance"].contains(kind)
        }.map { $0.element }
    }

    private func decodeState(_ data: Data?) -> [String: Any]? {
        guard let data = data,
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              state["revision"] is Int, state["episodes"] is [String: Any], state["queue"] is [[String: Any]] else { return nil }
        return state
    }

    private func acceptState(_ state: [String: Any]) {
        guard let next = state["revision"] as? Int, next >= revision else { return }
        revision = next
        let active = state["active_session"] as? [String: Any]
        lastRemoteOwner = active?["device_id"] as? String
        sessionId = lastRemoteOwner == deviceId ? active?["session_id"] as? String : nil
    }

    func fetchState(completion: @escaping ([String: Any]?) -> Void) {
        guard isConfigured, let token = credential else { completion(nil); return }
        httpClientGet(apiUrl + "/state", ["Authorization": "Bearer " + token]) { data, error in
            guard error == nil, let state = self.decodeState(data),
                  let next = state["revision"] as? Int, next >= self.revision else {
                completion(nil)
                return
            }
            self.acceptState(state)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: NSNotification.Name("podcold.sync.stateFetched"), object: state)
            }
            completion(state)
        }
    }

    func resolveEpisode(guid: String, completion: @escaping ([String: Any]?) -> Void) {
        guard isConfigured, let token = credential,
              let escaped = guid.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { completion(nil); return }
        httpClientGet(apiUrl + "/episodes/" + escaped, ["Authorization": "Bearer " + token]) { data, error in
            guard error == nil, let data = data,
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  value["audio_url"] is String, value["audio_version"] is String else { completion(nil); return }
            completion(value)
        }
    }

    func hasPendingQueueEdits(_ completion: @escaping (Bool) -> Void) {
        bgQueue.async {
            let pending = self.pendingEvents.contains { ($0["type"] as? String)?.hasPrefix("queue_") == true }
            DispatchQueue.main.async { completion(pending) }
        }
    }

    #if canImport(UIKit)
    func beginSyncing() {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.beginSyncing() }; return }
        guard isConfigured else { return }
        timer?.invalidate()
        timer = Timer(timeInterval: 20, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
        RunLoop.main.add(timer!, forMode: .common)
        refresh()
    }
    @objc private func refresh() {
        fetchState { _ in self.flushPending() }
    }
    #endif
}

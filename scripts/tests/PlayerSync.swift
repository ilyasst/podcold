import Foundation

extension Notification.Name {
    static let episodeLibraryChanged = Notification.Name("test.library")
}

class AudioPlayer {
    static let shared = AudioPlayer()
    var currentEpisode: Episode?
}

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

@main enum PlayerSyncTests {
    static var count = 0
    static func check(_ value: @autoclosure () -> Bool, _ label: String) {
        precondition(value(), label)
        count += 1
    }
    static func wait(_ semaphore: DispatchSemaphore) {
        check(semaphore.wait(timeout: .now() + 3) == .success, "Request completed")
        Thread.sleep(forTimeInterval: 0.05)
    }
    static func main() {
        let ud = UserDefaults.standard
        for key in ["paz_sync_url", "paz_sync_device_id", "paz_sync_credential", "paz_sync_revision", "paz_sync_session_id", "paz_sync_pending_events"] {
            ud.removeObject(forKey: key)
        }
        let sync = PlayerSyncClient.shared
        check(!sync.isConfigured, "Initially disconnected")
        sync.apiUrl = "https://sync.example.com/"
        check(sync.apiUrl == "https://sync.example.com/api/player/v1", "Origin expands to API")
        sync.deviceId = "dev-123"
        sync.credential = "secret"
        let fixture = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "scripts/tests/fixture.json"))) as! [String: Any]
        var state = fixture["state_response"] as! [String: Any]
        func encoded(_ value: [String: Any]) -> Data { return try! JSONSerialization.data(withJSONObject: value) }
        sync.httpClientGet = { url, headers, completion in completion(encoded(state), nil) }
        sync.fetchState { value in check(value?["revision"] as? Int == 42, "Fetch valid state") }
        check(sync.sessionId == "sess-xyz", "Only own session acquired")
        let signal = DispatchSemaphore(value: 0)
        var requests: [[String: Any]] = []
        sync.httpClientPost = { url, headers, body, completion in
            check(url.hasSuffix("/api/player/v1/events"), "Canonical event route")
            requests.append(body)
            var response = state
            response["revision"] = requests.count == 1 ? 45 : 46
            response["conflict"] = requests.count == 1
            completion(encoded(response), nil)
            if requests.count == 2 { signal.signal() }
        }
        sync.postEvent(type: "queue_add", params: ["episode_guid": "new-999", "origin": "manual"])
        wait(signal)
        check(requests.count == 2, "Independent edit retries once")
        check(requests[0]["event_id"] as? String == requests[1]["event_id"] as? String, "Retry preserves idempotency key")
        check(requests[1]["base_revision"] as? Int == 45, "Retry rebases revision")

        requests.removeAll()
        sync.httpClientPost = { _, _, body, completion in
            requests.append(body)
            completion(encoded(["revision": 47]), nil)
            signal.signal()
        }
        sync.postEvent(type: "checkpoint", params: ["episode_guid": "abc-123", "position_seconds": 155.0])
        wait(signal)
        check(requests[0]["session_id"] as? String == "sess-xyz", "Checkpoint uses owned session")
        let pending = try! JSONSerialization.jsonObject(with: ud.data(forKey: "paz_sync_pending_events")!) as! [[String: Any]]
        check(pending.count == 1, "Malformed acknowledgement preserves durable event")
        sync.httpClientPost = { _, _, body, completion in
            requests.append(body)
            var response = state
            response["revision"] = 47
            completion(encoded(response), nil)
            signal.signal()
        }
        sync.flushPending()
        wait(signal)
        check(requests[0]["event_id"] as? String == requests[1]["event_id"] as? String, "Durable retry keeps identity")

        var active = state["active_session"] as! [String: Any]
        active["device_id"] = "another-device"
        active["session_id"] = "foreign-session"
        state["active_session"] = active
        state["revision"] = 50
        sync.fetchState { _ in }
        check(sync.sessionId == nil, "Foreign session never adopted")
        requests.removeAll()
        sync.postEvent(type: "checkpoint", params: ["episode_guid": "abc-123", "position_seconds": 999.0])
        Thread.sleep(forTimeInterval: 0.1)
        check(requests.isEmpty, "Foreign playback is protected")
        sync.disconnect()
        Thread.sleep(forTimeInterval: 0.1)
        print("Passed \(count) sync checks.")
    }
}

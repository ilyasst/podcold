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
    private static var count = 0
    private static func check(_ value: @autoclosure () -> Bool, _ label: String) {
        precondition(value(), label); count += 1
    }

    private static func reset() {
        let ud = UserDefaults.standard
        for key in ["paz_sync_url", "paz_sync_device_id", "paz_sync_credential", "paz_sync_revision", "paz_sync_session_id", "paz_sync_pending_events"] {
            ud.removeObject(forKey: key)
        }
    }

    static func main() {
        reset()

        let sync = PlayerSyncClient.shared
        check(!sync.isConfigured, "Sync is not configured initially")

        sync.apiUrl = "https://sync.example.com"
        sync.deviceId = "dev-123"
        sync.credential = "secret"
        check(sync.isConfigured, "Sync is configured")

        var postCalled = false
        sync.httpClientPost = { url, headers, body, completion in
            postCalled = true
            completion("{}".data(using: .utf8), nil)
        }

        sync.postEvent(type: "checkpoint", params: ["episode_guid": "test", "position_seconds": 12.0], immediate: true)

        // Sleep a little to wait for background queue
        Thread.sleep(forTimeInterval: 0.1)
        check(postCalled, "postEvent triggers flushPending")

        testFixture()

        print("Passed \(count) sync checks.")
    }

    private static func testFixture() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: "scripts/tests/fixture.json")),
              let fixture = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stateResp = fixture["state_response"] as? [String: Any],
              let eventReqs = fixture["event_requests"] as? [String: [String: Any]] else {
            fatalError("Cannot load fixture.json")
        }

        let sync = PlayerSyncClient.shared

        // Mock GET
        sync.httpClientGet = { url, headers, completion in
            let jsonData = try? JSONSerialization.data(withJSONObject: stateResp)
            completion(jsonData, nil)
        }

        var fetchCompleted = false
        sync.fetchState { state in
            check(state?["revision"] as? Int == 42, "State revision parsed")
            check(sync.sessionId == "sess-xyz", "Session ID extracted")
            fetchCompleted = true
        }
        check(fetchCompleted, "Fetch state completed")

        // Mock POST to validate events against fixture
        var postedEvent: [String: Any]?
        sync.httpClientPost = { url, headers, body, completion in
            postedEvent = body
            completion("{\"revision\": 43}".data(using: .utf8), nil)
        }

        // Test start event
        sync.postEvent(type: "start", params: [
            "episode_guid": "abc-123",
            "audio_version": "v2",
            "position_seconds": 0.0,
            "duration_seconds": 3600.0
        ], immediate: true)
        Thread.sleep(forTimeInterval: 0.1)
        check(postedEvent?["type"] as? String == "start", "Posted start event")
        check(postedEvent?["episode_guid"] as? String == eventReqs["start"]?["episode_guid"] as? String, "Start payload matches fixture")

        // Test checkpoint event
        sync.postEvent(type: "checkpoint", params: [
            "session_id": sync.sessionId ?? "",
            "episode_guid": "abc-123",
            "audio_version": "v2",
            "position_seconds": 155.0,
            "duration_seconds": 3600.0
        ], immediate: true)
        Thread.sleep(forTimeInterval: 0.1)
        check(postedEvent?["session_id"] as? String == eventReqs["checkpoint"]?["session_id"] as? String, "Checkpoint payload matches fixture")
    }
}

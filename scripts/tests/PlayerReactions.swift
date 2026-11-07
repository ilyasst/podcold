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

@main enum PlayerReactionsTests {
    private static var count = 0
    private static func check(_ value: @autoclosure () -> Bool, _ label: String) {
        precondition(value(), label); count += 1
    }

    private static func reset() {
        let ud = UserDefaults.standard
        for key in ["paz_sync_url", "paz_sync_device_id", "paz_sync_credential"] {
            ud.removeObject(forKey: key)
        }
    }

    static func main() {
        reset()
        let sync = PlayerSyncClient.shared
        sync.apiUrl = "https://sync.example.com"
        sync.deviceId = "dev-123"
        sync.credential = "secret"

        let reactions = PlayerReactionClient.shared
        check(reactions.isConfigured, "Reaction client configured via sync client")

        guard let fixtureData = try? Data(contentsOf: URL(fileURLWithPath: "scripts/tests/fixture.json")),
              let fixture = try? JSONSerialization.jsonObject(with: fixtureData) as? [String: Any],
              let reactionsResp = fixture["reactions_get_response"] as? [String: Any],
              let reactionEventRequests = fixture["reactions_post_request"] as? [String: [String: Any]],
              let promptEventRequests = fixture["prompts_post_request"] as? [String: [String: Any]] else {
            fatalError("Cannot load fixture.json")
        }

        var getCalled = false
        reactions.httpClientGet = { url, headers, completion in
            getCalled = true
            let data = try? JSONSerialization.data(withJSONObject: reactionsResp)
            completion(data, nil)
        }

        var pref: String?
        reactions.fetchReactions(episodeGuid: "abc-123") { data in
            pref = data?["preference"] as? String
        }
        check(getCalled, "fetchReactions makes a GET request")
        check(pref == "more", "fetchReactions parses response")

        var postedAction: [String: Any]?
        reactions.httpClientPost = { url, headers, body, completion in
            postedAction = body
            completion("{\"status\":\"ok\"}".data(using: .utf8), nil)
        }

        reactions.postReaction(episodeGuid: "abc-123", action: "pass", preferenceVersion: "10")
        check(postedAction?["action"] as? String == reactionEventRequests["pass"]?["action"] as? String, "postReaction sends pass action from fixture")
        check(postedAction?["preference_version"] as? String == reactionEventRequests["pass"]?["preference_version"] as? String, "postReaction sends preference_version from fixture")

        var postedPromptAction: [String: Any]?
        reactions.httpClientPost = { url, headers, body, completion in
            postedPromptAction = body
            completion("{\"status\":\"ok\"}".data(using: .utf8), nil)
        }

        reactions.postPrompt(episodeGuid: "abc-123", action: "dismissed")
        check(postedPromptAction?["action"] as? String == promptEventRequests["dismissed"]?["action"] as? String, "postPrompt sends dismissed action from fixture")

        print("Passed \(count) reaction checks.")
    }
}

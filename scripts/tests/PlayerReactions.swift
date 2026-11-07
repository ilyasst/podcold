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
        for key in ["paz_sync_url", "paz_sync_device_id", "paz_sync_credential", "podcold_prompt_opt_out"] {
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

        // FeedbackManager Regression Checks
        let fm = FeedbackManager.shared

        // 1. Eligibility transitions & Prompt timing
        var getReqCount = 0
        reactions.httpClientGet = { url, headers, completion in
            getReqCount += 1
            let resp = ["eligible_for_prompt": true, "preference_version": "v1"] as [String: Any]
            completion(try? JSONSerialization.data(withJSONObject: resp), nil)
        }

        fm.loadEpisode(guid: "ep-1") { _ in }
        check(fm.isEligibleForPrompt, "Manager becomes eligible on load")
        check(fm.currentEpisodeGuid == "ep-1", "Manager sets episode guid")
        check(getReqCount == 1, "loadEpisode makes GET request")

        // 2. Cross-device claim refusal
        reactions.httpClientGet = { url, headers, completion in
            // Another device already claimed it
            let resp = ["eligible_for_prompt": false, "preference_version": "v1"] as [String: Any]
            completion(try? JSONSerialization.data(withJSONObject: resp), nil)
        }

        var promptShown = false
        fm.checkPromptAtNaturalBreak { success, guid in
            promptShown = success
        }
        check(!promptShown, "Prompt is not shown if claim fails (cross-device refusal)")
        check(!fm.isEligibleForPrompt, "Manager eligibility transitions to false")

        // Eligibility can race another device, so the actual claim must succeed.
        reactions.httpClientGet = { _, _, completion in
            completion(try? JSONSerialization.data(withJSONObject: ["eligible_for_prompt": true]), nil)
        }
        reactions.httpClientPost = { _, _, _, completion in
            completion(try? JSONSerialization.data(withJSONObject: ["status": "ok", "claimed": false]), nil)
        }
        fm.checkPromptAtNaturalBreak { shown, _ in
            check(!shown, "Server claim refusal suppresses the popup")
        }
        reactions.httpClientPost = { _, _, _, completion in
            completion(try? JSONSerialization.data(withJSONObject: ["status": "ok", "claimed": true]), nil)
        }
        fm.checkPromptAtNaturalBreak { shown, _ in
            check(shown, "Successful server claim permits the popup")
        }

        // 3. Stale responses
        fm.loadEpisode(guid: "ep-2") { _ in }
        reactions.httpClientGet = { url, headers, completion in
            // Simulate delayed response for ep-2 after episode changed
            let resp = ["eligible_for_prompt": true, "preference_version": "v1"] as [String: Any]
            // Change episode before completion
            fm.currentEpisodeGuid = "ep-3"
            completion(try? JSONSerialization.data(withJSONObject: resp), nil)
        }
        fm.loadEpisode(guid: "ep-2") { _ in }
        check(fm.currentEpisodeGuid == "ep-3", "Episode changed")
        check(!fm.isEligibleForPrompt, "Stale response does not update eligibility")

        // 4. Opt-out
        var postedOptOut: [String: Any]?
        reactions.httpClientPost = { url, headers, body, completion in
            postedOptOut = body

            completion("{\"status\":\"ok\"}".data(using: .utf8), nil)
        }
        fm.handlePromptAction(guid: "ep-3", action: "opt_out")
        check(postedOptOut?["action"] as? String == "opt_out", "Opt-out is shared with the server")

        // 5. Immediate Undo & Episode changes during a reaction
        reactions.httpClientGet = { url, headers, completion in
            let resp = ["eligible_for_prompt": false, "preference_version": "v2"] as [String: Any]
            completion(try? JSONSerialization.data(withJSONObject: resp), nil)
        }
        reactions.httpClientPost = { url, headers, body, completion in
            let resp = ["status": "ok"]
            // Simulate episode change during inflight reaction
            fm.currentEpisodeGuid = "ep-4"
            completion(try? JSONSerialization.data(withJSONObject: resp), nil)
        }
        fm.currentEpisodeGuid = "ep-3"
        fm.currentPreferenceVersion = "v1"
        fm.submitReaction(guid: "ep-3", action: "undo", preferenceVersion: "v1") { success in
            check(success, "Undo succeeds")
        }
        check(fm.currentPreferenceVersion == "v1", "Preference version not updated for old episode (episode changed during reaction)")

        // Test updating version normally
        reactions.httpClientPost = { url, headers, body, completion in
            let resp = ["status": "ok"]
            completion(try? JSONSerialization.data(withJSONObject: resp), nil)
        }
        fm.currentEpisodeGuid = "ep-4"
        fm.submitReaction(guid: "ep-4", action: "more", preferenceVersion: "v1") { _ in }
        check(fm.currentPreferenceVersion == "v2", "Immediate Undo: preference version refreshes on success")

        print("Passed \(count) reaction checks.")
    }
}

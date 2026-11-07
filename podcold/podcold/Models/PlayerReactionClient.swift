import Foundation

class PlayerReactionClient {
    static let shared = PlayerReactionClient()

    var isConfigured: Bool {
        return PlayerSyncClient.shared.isConfigured
    }

    // Injectable for tests
    var httpClientGet: (String, [String: String], @escaping (Data?, Error?) -> Void) -> Void = { url, headers, completion in
        #if canImport(UIKit)
        HTTPClient.get(url: url, headers: headers, completion: completion)
        #else
        fatalError("Inject HTTPClient.get")
        #endif
    }

    var httpClientPost: (String, [String: String], [String: Any], @escaping (Data?, Error?) -> Void) -> Void = { url, headers, body, completion in
        #if canImport(UIKit)
        HTTPClient.post(url: url, headers: headers, body: body, completion: completion)
        #else
        fatalError("Inject HTTPClient.post")
        #endif
    }

    func fetchReactions(episodeGuid: String, completion: @escaping ([String: Any]?) -> Void) {
        guard isConfigured, let cred = PlayerSyncClient.shared.credential else { completion(nil); return }

        let headers = ["Authorization": "Bearer \(cred)"]
        let url = "\(PlayerSyncClient.shared.apiUrl)/reactions/\(episodeGuid)"

        httpClientGet(url, headers) { data, error in
            guard let data = data, let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(nil)
                return
            }
            completion(response)
        }
    }

    func postReaction(episodeGuid: String, action: String, preferenceVersion: String?, completion: ((Bool, String?) -> Void)? = nil) {
        guard isConfigured, let cred = PlayerSyncClient.shared.credential else { completion?(false, nil); return }

        var payload: [String: Any] = [
            "event_id": UUID().uuidString,
            "episode_guid": episodeGuid,
            "action": action
        ]
        if let pv = preferenceVersion {
            payload["preference_version"] = pv
        }

        let headers = ["Authorization": "Bearer \(cred)"]
        let url = "\(PlayerSyncClient.shared.apiUrl)/reactions"

        httpClientPost(url, headers, payload) { data, error in
            guard error == nil, let data = data,
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = dict["status"] as? String, status == "ok" else {
                completion?(false, nil)
                return
            }
            let updatedVersion = dict["preference_version"] as? String
            completion?(true, updatedVersion)
        }
    }

    func postPrompt(episodeGuid: String, action: String) {
        guard isConfigured, let cred = PlayerSyncClient.shared.credential else { return }

        let payload: [String: Any] = [
            "event_id": UUID().uuidString,
            "episode_guid": episodeGuid,
            "action": action
        ]

        let headers = ["Authorization": "Bearer \(cred)"]
        let url = "\(PlayerSyncClient.shared.apiUrl)/prompts"

        httpClientPost(url, headers, payload) { _, _ in }
    }
}

class FeedbackManager {
    static let shared = FeedbackManager()
    
    var currentEpisodeGuid: String?
    var currentPreferenceVersion: String?
    var isEligibleForPrompt: Bool = false
    var promptShown: Bool = false
    
    func isConfigured() -> Bool {
        return PlayerReactionClient.shared.isConfigured
    }
    
    func loadEpisode(guid: String, completion: @escaping (String?) -> Void) {
        currentEpisodeGuid = guid
        promptShown = false
        isEligibleForPrompt = false
        PlayerReactionClient.shared.fetchReactions(episodeGuid: guid) { [weak self] response in
            guard self?.currentEpisodeGuid == guid else { return } // Stale response check
            self?.isEligibleForPrompt = (response?["eligible_for_prompt"] as? Bool) ?? false
            self?.currentPreferenceVersion = response?["preference_version"] as? String
            completion(response?["preference"] as? String)
        }
    }
    
    func checkPromptAtNaturalBreak(completion: @escaping (Bool, String) -> Void) {
        guard let guid = currentEpisodeGuid, isEligibleForPrompt, !promptShown else { return }
        
        PlayerReactionClient.shared.fetchReactions(episodeGuid: guid) { [weak self] response in
            guard self?.currentEpisodeGuid == guid else { return }
            if let eligible = response?["eligible_for_prompt"] as? Bool, eligible {
                self?.promptShown = true
                completion(true, guid)
            } else {
                self?.isEligibleForPrompt = false
                completion(false, guid)
            }
        }
    }
    
    func submitReaction(guid: String, action: String, preferenceVersion: String?, completion: @escaping (Bool) -> Void) {
        PlayerReactionClient.shared.postReaction(episodeGuid: guid, action: action, preferenceVersion: preferenceVersion) { [weak self] success, updatedVersion in
            if success, self?.currentEpisodeGuid == guid {
                self?.currentPreferenceVersion = updatedVersion
            }
            completion(success)
        }
    }
    
    func handlePromptAction(guid: String, action: String) {
        PlayerReactionClient.shared.postPrompt(episodeGuid: guid, action: action)
    }
}

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
    
    func postReaction(episodeGuid: String, action: String, preferenceVersion: Int?, completion: ((Bool) -> Void)? = nil) {
        guard isConfigured, let cred = PlayerSyncClient.shared.credential else { completion?(false); return }
        
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
            completion?(error == nil)
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

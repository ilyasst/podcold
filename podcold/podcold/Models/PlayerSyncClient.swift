import Foundation
#if canImport(UIKit)
import UIKit
#endif

class PlayerSyncClient {
    static let shared = PlayerSyncClient()
    
    private let urlKey = "paz_sync_url"
    private let deviceIdKey = "paz_sync_device_id"
    private let credentialKey = "paz_sync_credential"
    private let revisionKey = "paz_sync_revision"
    private let sessionIdKey = "paz_sync_session_id"
    
    var apiUrl: String {
        get { return UserDefaults.standard.string(forKey: urlKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: urlKey) }
    }
    
    var deviceId: String? {
        get { return UserDefaults.standard.string(forKey: deviceIdKey) }
        set { UserDefaults.standard.set(newValue, forKey: deviceIdKey) }
    }
    
    var credential: String? {
        get { return UserDefaults.standard.string(forKey: credentialKey) }
        set { UserDefaults.standard.set(newValue, forKey: credentialKey) }
    }
    
    var revision: Int {
        get { return UserDefaults.standard.integer(forKey: revisionKey) }
        set { UserDefaults.standard.set(newValue, forKey: revisionKey) }
    }
    
    var sessionId: String {
        get {
            if let id = UserDefaults.standard.string(forKey: sessionIdKey) { return id }
            let id = UUID().uuidString
            UserDefaults.standard.set(id, forKey: sessionIdKey)
            return id
        }
    }
    
    var isConfigured: Bool {
        return !apiUrl.isEmpty && credential != nil && deviceId != nil
    }
    
    private let bgQueue = DispatchQueue(label: "com.podcold.sync")
    private var pendingEvents: [[String: Any]] = []
    private let pendingEventsKey = "paz_sync_pending_events"
    
    // Injectable for tests
    var httpClientPost: (String, [String: String], [String: Any], @escaping (Data?, Error?) -> Void) -> Void = { url, headers, body, completion in
        #if canImport(UIKit)
        HTTPClient.post(url: url, headers: headers, body: body, completion: completion)
        #else
        fatalError("Inject HTTPClient.post")
        #endif
    }
    
    var httpClientGet: (String, [String: String], @escaping (Data?, Error?) -> Void) -> Void = { url, headers, completion in
        #if canImport(UIKit)
        HTTPClient.get(url: url, headers: headers, completion: completion)
        #else
        fatalError("Inject HTTPClient.get")
        #endif
    }
    
    init() {
        if let data = UserDefaults.standard.data(forKey: pendingEventsKey),
           let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            pendingEvents = list
        }
        
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
        #endif
    }
    
    private func savePending() {
        if let data = try? JSONSerialization.data(withJSONObject: pendingEvents) {
            UserDefaults.standard.set(data, forKey: pendingEventsKey)
            UserDefaults.standard.synchronize()
        }
    }
    
    func enroll(code: String, label: String, completion: @escaping (Bool, String?) -> Void) {
        guard !apiUrl.isEmpty else { completion(false, "API URL not set"); return }
        
        let payload: [String: Any] = ["code": code, "label": label]
        httpClientPost(apiUrl + "/pair", [:], payload) { data, error in
            guard let data = data, let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let devId = dict["device_id"] as? String, let cred = dict["credential"] as? String else {
                completion(false, error?.localizedDescription ?? "Invalid response")
                return
            }
            self.deviceId = devId
            self.credential = cred
            completion(true, nil)
        }
    }
    
    func postEvent(type: String, params: [String: Any], immediate: Bool = false) {
        guard isConfigured else { return }
        bgQueue.async {
            var event = params
            event["event_id"] = UUID().uuidString
            event["type"] = type
            event["base_revision"] = self.revision
            
            self.pendingEvents.append(event)
            self.savePending()
            
            if immediate {
                self.flushPending()
            }
        }
    }
    
    func flushPending() {
        guard isConfigured, let cred = credential else { return }
        
        bgQueue.async {
            let events = self.pendingEvents
            guard !events.isEmpty else { return }
            
            guard let event = events.first else { return }
            
            let headers = ["Authorization": "Bearer \(cred)"]
            self.httpClientPost(self.apiUrl + "/events", headers, event) { data, error in
                guard error == nil, let data = data,
                      let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return
                }
                
                self.bgQueue.async {
                    if let conflict = response["conflict"] as? Bool, conflict {
                        // Someone else took over, pause local playback
                        DispatchQueue.main.async {
                            // Note: AudioPlayer isn't known to PlayerSyncClient directly if not injected,
                            // but we can post a notification or call AudioPlayer.shared.pause() 
                            // Since this is models layer, let's just post a notification or pause directly.
                            // But wait, the test doesn't have AudioPlayer mocked with pause.
                            // We can use NotificationCenter
                            NotificationCenter.default.post(name: NSNotification.Name("podcold.sync.conflict"), object: nil)
                        }
                        self.pendingEvents.removeAll() // Clear pending to prevent more conflicts
                        self.savePending()
                        return
                    }
                    
                    self.pendingEvents.removeFirst()
                    self.savePending()
                    
                    if let rev = response["revision"] as? Int {
                        self.revision = max(self.revision, rev)
                    }
                    
                    if !self.pendingEvents.isEmpty {
                        self.flushPending()
                    }
                }
            }
        }
    }
    
    func fetchState(completion: @escaping ([String: Any]?) -> Void) {
        guard isConfigured, let cred = credential else { completion(nil); return }
        
        let headers = ["Authorization": "Bearer \(cred)"]
        self.httpClientGet(apiUrl + "/state", headers) { data, error in
            guard let data = data, let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(nil)
                return
            }
            if let rev = response["revision"] as? Int {
                self.revision = max(self.revision, rev)
            }
            completion(response)
        }
    }
    
    #if canImport(UIKit)
    @objc private func appDidEnterBackground() {
        flushPending()
    }
    #endif
}

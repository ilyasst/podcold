import Foundation

extension Notification.Name {
    static let episodeLibraryChanged = Notification.Name("podcold.library.changed")
}

class EpisodeDownloader {
    private class Transfer {
        var progress: Float = 0
        var listeners: [((Float) -> Void, (Bool) -> Void)] = []
    }
    private static var transfers: [String: Transfer] = [:]


    // Static per the queue rule — one thread, created at class load, used once.
    private static let sweepQueue = DispatchQueue(label: "com.podcold.downloadsweep")

    // A download interrupted by a crash or force-quit leaves its ".part" sidecar
    // behind (CurlFetcher only unlinks it on a clean failure). Nothing ever reads
    // those files, so they would just accumulate in Documents. Called once from
    // AppDelegate at launch.
    static func sweepStalePartFiles(completion: @escaping () -> Void) {
        sweepQueue.async {
            defer { DispatchQueue.main.async(execute: completion) }
            let fm = FileManager.default
            let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first!
            guard let names = try? fm.contentsOfDirectory(atPath: docs) else { return }
            for name in names where name.hasSuffix(".part") {
                try? fm.removeItem(atPath: (docs as NSString).appendingPathComponent(name))
            }
        }
    }

    static func download(episode: Episode,
                         progress: @escaping (Float) -> Void,
                         completion: @escaping (Bool) -> Void) {
        // All callers use the main thread. A manual request joins an automatic
        // transfer instead of rewriting the same .part file or downloading twice.
        if !Thread.isMainThread {
            DispatchQueue.main.async { download(episode: episode, progress: progress, completion: completion) }
            return
        }
        guard !episode.audioUrl.isEmpty else { completion(false); return }
        if episode.localPath() != nil { completion(true); return }
        if let transfer = transfers[episode.guid] {
            transfer.listeners.append((progress, completion))
            progress(transfer.progress)
            return
        }
        let transfer = Transfer()
        transfer.listeners.append((progress, completion))
        transfers[episode.guid] = transfer
        CurlFetcher.downloadToFile(url: episode.audioUrl, outputPath: episode.localPathForWriting(), progress: { value in
            transfer.progress = value
            for listener in transfer.listeners { listener.0(value) }
        }) { ok in
            transfers.removeValue(forKey: episode.guid)
            if ok {
                Episode.addToDownloads(episode)
                PlayQueue.shared.offerAutomatically(episode, source: .download)
            }
            // Complete ownership bookkeeping before notifying automatic refill.
            for listener in transfer.listeners { listener.1(ok) }
            NotificationCenter.default.post(name: .episodeLibraryChanged, object: nil)
        }
    }
}

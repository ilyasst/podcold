import UIKit

class DownloadsVC: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let tableView = UITableView()
    private var episodes: [Episode] = []
    private var episodeSizes: [String: String] = [:]
    private let playlistActions = EpisodePlaylistActions()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Downloads"
        view.backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.14, alpha: 1)

        tableView.frame            = view.bounds
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tableView.dataSource       = self
        tableView.delegate         = self
        tableView.backgroundColor  = .clear
        tableView.separatorColor   = UIColor(white: 0.2, alpha: 1)
        tableView.rowHeight        = 68
        tableView.contentInset     = UIEdgeInsets(top: 0, left: 0, bottom: 60, right: 0)
        view.addSubview(tableView)
        tableView.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(episodeHeld(_:))))
        NotificationCenter.default.addObserver(self, selector: #selector(reloadDownloads), name: .episodeLibraryChanged, object: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadDownloadsFromDisk()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func reloadDownloads() {
        guard isViewLoaded, view.window != nil else { return }
        reloadDownloadsFromDisk()
    }

    private func reloadDownloadsFromDisk() {
        let loaded = Episode.loadDownloads()
        episodes = loaded
        // stat() on flash is <0.1ms per file — synchronous precompute avoids double reloadData
        episodeSizes = [:]
        for ep in loaded { episodeSizes[ep.guid] = ep.fileSizeString() }
        tableView.reloadData()
        if episodes.isEmpty { showEmptyState() } else { hideEmptyState() }
    }

    // MARK: - Empty state

    private var emptyLabel: UILabel?

    private func showEmptyState() {
        guard emptyLabel == nil else { return }
        let l = UILabel(frame: CGRect(x: 20, y: 0, width: view.bounds.width - 40, height: 60))
        l.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY - 40)
        l.text = "No downloaded episodes"
        l.textColor = UIColor(white: 0.35, alpha: 1)
        l.backgroundColor = .clear
        l.font = UIFont.systemFont(ofSize: 15)
        l.textAlignment = .center
        view.addSubview(l)
        emptyLabel = l
    }

    private func hideEmptyState() {
        emptyLabel?.removeFromSuperview()
        emptyLabel = nil
    }

    // MARK: - UITableViewDataSource

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return episodes.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "dl") ??
                   UITableViewCell(style: .subtitle, reuseIdentifier: "dl")
        let ep = episodes[indexPath.row]
        cell.accessibilityIdentifier = ep.guid

        cell.textLabel?.text          = ep.title
        cell.textLabel?.textColor     = .white
        cell.textLabel?.numberOfLines = 2
        cell.textLabel?.backgroundColor = .clear

        let size = episodeSizes[ep.guid] ?? ""
        let detail = [ep.podcastTitle, ep.duration, size].filter { !$0.isEmpty }.joined(separator: " · ")
        cell.detailTextLabel?.text      = detail
        cell.detailTextLabel?.textColor = UIColor(white: 0.5, alpha: 1)
        cell.detailTextLabel?.backgroundColor = .clear

        cell.backgroundColor = .clear
        cell.accessoryType   = .disclosureIndicator

        cell.imageView?.image = nil
        if !ep.artworkUrl.isEmpty {
            let url = ep.artworkUrl
            AsyncImageView.loadCell(url: url) { [weak cell] img in
                // A warm cache calls back inline during cellForRowAt. Asking the
                // table for that row again can re-enter the data source forever.
                // Capture the cell itself and check identity in case it was reused.
                guard let cell = cell, cell.accessibilityIdentifier == ep.guid else { return }
                cell.imageView?.image = img
                cell.setNeedsLayout()
            }
        }
        return cell
    }

    func tableView(_ tableView: UITableView,
                   commit editingStyle: UITableViewCell.EditingStyle,
                   forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete, indexPath.row < episodes.count else { return }
        let ep = episodes[indexPath.row]
        // AVPlayer is reading this exact file. Pulling it out from under the player
        // leaves it on a deleted inode and playback dies a few seconds later with no
        // explanation. Refusing is recoverable; killing playback on a swipe is not.
        guard AudioPlayer.shared.currentEpisode?.guid != ep.guid else {
            tableView.setEditing(false, animated: true)
            let a = UIAlertView()
            a.title   = "Still Playing"
            a.message = "Close the player before deleting this download."
            a.addButton(withTitle: "OK")
            a.show()
            return
        }
        if let path = ep.localPath() {
            try? FileManager.default.removeItem(atPath: path)
        }
        Episode.removeFromDownloads(guid: ep.guid)
        episodes.remove(at: indexPath.row)
        tableView.deleteRows(at: [indexPath], with: .automatic)
        if episodes.isEmpty { showEmptyState() }
    }

    // MARK: - UITableViewDelegate

    @objc private func episodeHeld(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began,
              let path = tableView.indexPathForRow(at: gesture.location(in: tableView)),
              path.row < episodes.count else { return }
        playlistActions.show(episode: episodes[path.row], in: view)
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.row < episodes.count else { return }
        let ep = episodes[indexPath.row]
        let podcast = Podcast.loadSubscriptions().first { $0.title == ep.podcastTitle } ?? {
            let p = Podcast()
            p.title         = ep.podcastTitle
            p.artworkUrl600 = ep.artworkUrl
            p.artworkUrl    = ep.artworkUrl
            return p
        }()
        navigationController?.pushViewController(
            EpisodeDetailVC(episode: ep, podcast: podcast), animated: true)
    }
}

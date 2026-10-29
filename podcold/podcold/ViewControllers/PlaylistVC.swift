import UIKit

// This is the same persisted list used by Now Playing, not a second queue.
class PlaylistVC: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let tableView = UITableView()
    private let playButton = UIButton(type: .custom)
    private let countLabel = UILabel()
    private let emptyLabel = UILabel()
    private var episodes: [Episode] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Playlist"
        view.backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.14, alpha: 1)
        navigationItem.rightBarButtonItems = [editButtonItem,
            UIBarButtonItem(title: "Options", style: .plain, target: self, action: #selector(openSettings))]
        tableView.frame = view.bounds
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tableView.backgroundColor = .clear
        tableView.separatorColor = UIColor(white: 0.2, alpha: 1)
        tableView.rowHeight = 72
        tableView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 60, right: 0)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.accessibilityIdentifier = "playlist-table"
        view.addSubview(tableView)
        let header = UIView(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 104))
        playButton.frame = CGRect(x: 16, y: 12, width: view.bounds.width - 32, height: 42)
        playButton.autoresizingMask = .flexibleWidth
        playButton.backgroundColor = UIColor(red: 0.53, green: 0.26, blue: 0.73, alpha: 1)
        playButton.layer.cornerRadius = 8
        playButton.accessibilityIdentifier = "play-playlist"
        playButton.addTarget(self, action: #selector(playPlaylist), for: .touchUpInside)
        header.addSubview(playButton)
        countLabel.frame = CGRect(x: 16, y: 62, width: view.bounds.width - 32, height: 34)
        countLabel.autoresizingMask = .flexibleWidth
        countLabel.textColor = UIColor(white: 0.6, alpha: 1)
        countLabel.backgroundColor = .clear
        countLabel.font = UIFont.systemFont(ofSize: 12)
        countLabel.numberOfLines = 2
        header.addSubview(countLabel)
        tableView.tableHeaderView = header
        emptyLabel.text = "Your playlist is empty.\nHold an episode to add it, or set automatic adding in Options."
        emptyLabel.numberOfLines = 0
        emptyLabel.textAlignment = .center
        emptyLabel.textColor = UIColor(white: 0.55, alpha: 1)
        emptyLabel.backgroundColor = .clear
        emptyLabel.font = UIFont.systemFont(ofSize: 15)
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(reloadPlaylist), name: .playQueueChanged, object: nil)
        nc.addObserver(self, selector: #selector(reloadPlaylist), name: .episodeLibraryChanged, object: nil)
        nc.addObserver(self, selector: #selector(reloadPlaylist), name: .playerStateChanged, object: nil)
        reloadPlaylist()
    }

    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); reloadPlaylist() }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func reloadPlaylist() {
        guard isViewLoaded else { return }
        episodes = PlayQueue.shared.episodes
        tableView.reloadData()
        countLabel.text = "\(episodes.count) up next · Limit \(PlayQueue.maximumSize)\nEpisodes play in order. Edit to rearrange."
        tableView.backgroundView = episodes.isEmpty ? emptyLabel : nil
        editButtonItem.isEnabled = !episodes.isEmpty
        let player = AudioPlayer.shared
        let current = player.currentEpisode != nil && (player.state == .paused || player.isPlaying)
        playButton.setTitle(player.isPlaying ? "Now Playing" : current ? "Resume playlist" : "Play playlist", for: .normal)
        playButton.isEnabled = current || !episodes.isEmpty
        playButton.alpha = playButton.isEnabled ? 1 : 0.4
    }

    @objc private func openSettings() { navigationController?.pushViewController(PlaylistSettingsVC(), animated: true) }

    @objc private func playPlaylist() {
        let player = AudioPlayer.shared
        if player.currentEpisode != nil && player.state == .paused { player.resume() }
        else if !player.isPlaying, let next = PlayQueue.shared.next() { player.play(episode: next) }
        guard player.currentEpisode != nil else { return }
        navigationController?.pushViewController(NowPlayingVC(), animated: true)
    }

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        tableView.setEditing(editing, animated: animated)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { return episodes.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "playlist") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "playlist")
        let ep = episodes[indexPath.row]
        cell.textLabel?.text = ep.title
        cell.textLabel?.textColor = .white
        cell.textLabel?.backgroundColor = .clear
        cell.textLabel?.numberOfLines = 2
        cell.textLabel?.font = UIFont.systemFont(ofSize: 14)
        cell.detailTextLabel?.text = [ep.podcastTitle, ep.localPath() == nil ? "Online" : "Downloaded"].filter { !$0.isEmpty }.joined(separator: " · ")
        cell.detailTextLabel?.textColor = UIColor(white: 0.55, alpha: 1)
        cell.detailTextLabel?.backgroundColor = .clear
        cell.backgroundColor = .clear
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool { return true }
    func tableView(_ tableView: UITableView, moveRowAt from: IndexPath, to: IndexPath) {
        guard from.row < episodes.count, to.row < episodes.count else { return }
        let guid = episodes[from.row].guid
        guard let current = PlayQueue.shared.episodes.firstIndex(where: { $0.guid == guid }) else { return }
        PlayQueue.shared.move(from: current, to: to.row)
        episodes = PlayQueue.shared.episodes
    }

    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete, indexPath.row < episodes.count else { return }
        // Snapshot by identity: a background download may have added another row.
        PlayQueue.shared.remove(guid: episodes[indexPath.row].guid)
        reloadPlaylist()
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.row < episodes.count else { return }
        let ep = episodes[indexPath.row]
        let podcast = Podcast.loadSubscriptions().first { $0.title == ep.podcastTitle } ?? Podcast()
        if podcast.title.isEmpty { podcast.title = ep.podcastTitle }
        navigationController?.pushViewController(EpisodeDetailVC(episode: ep, podcast: podcast), animated: true)
    }
}

import UIKit

class AddFeedVC: UIViewController, UITextFieldDelegate {
    private let urlField = UITextField()
    private let addButton = UIButton(type: .custom)
    private let statusLabel = UILabel()
    private var loading = false
    private let purple = UIColor(red: 0.53, green: 0.26, blue: 0.73, alpha: 1)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Add Feed URL"
        edgesForExtendedLayout = []
        view.backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.14, alpha: 1)
        let width = view.bounds.width
        let scroll = UIScrollView(frame: view.bounds)
        scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.contentSize = CGSize(width: width, height: 300)
        view.addSubview(scroll)

        let label = UILabel(frame: CGRect(x: 16, y: 16, width: width - 32, height: 22))
        label.text = "Paste the podcast's RSS feed link."
        label.textColor = .white
        label.font = UIFont.systemFont(ofSize: 14)
        label.backgroundColor = .clear
        scroll.addSubview(label)

        urlField.frame = CGRect(x: 16, y: 48, width: width - 32, height: 44)
        urlField.autoresizingMask = .flexibleWidth
        urlField.borderStyle = .roundedRect
        urlField.placeholder = "https://example.com/feed.xml"
        urlField.keyboardType = .URL
        urlField.returnKeyType = .go
        urlField.autocapitalizationType = .none
        urlField.autocorrectionType = .no
        urlField.clearButtonMode = .whileEditing
        urlField.delegate = self
        urlField.accessibilityIdentifier = "feed-url"
        scroll.addSubview(urlField)

        addButton.frame = CGRect(x: 16, y: 108, width: width - 32, height: 44)
        addButton.autoresizingMask = .flexibleWidth
        addButton.backgroundColor = purple
        addButton.layer.cornerRadius = 8
        addButton.setTitle("Add Feed", for: .normal)
        addButton.setTitleColor(.white, for: .normal)
        addButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 15)
        addButton.accessibilityIdentifier = "add-feed"
        addButton.addTarget(self, action: #selector(addFeed), for: .touchUpInside)
        scroll.addSubview(addButton)

        statusLabel.frame = CGRect(x: 16, y: 166, width: width - 32, height: 90)
        statusLabel.autoresizingMask = .flexibleWidth
        statusLabel.font = UIFont.systemFont(ofSize: 14)
        statusLabel.backgroundColor = .clear
        statusLabel.numberOfLines = 0
        statusLabel.accessibilityIdentifier = "feed-status"
        scroll.addSubview(statusLabel)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !loading { urlField.becomeFirstResponder() }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        addFeed()
        return true
    }

    private func setLoading(_ value: Bool) {
        loading = value
        addButton.isEnabled = !value
        urlField.isEnabled = !value
        addButton.alpha = value ? 0.6 : 1
        addButton.setTitle(value ? "Checking Feed..." : "Add Feed", for: .normal)
    }

    @objc private func addFeed() {
        guard !loading else { return }
        urlField.resignFirstResponder()
        guard let url = Podcast.normalizedFeedURL(urlField.text ?? "") else {
            showError("Enter an HTTP or HTTPS RSS feed link.")
            return
        }
        urlField.text = url
        if let existing = Podcast.subscription(feedUrl: url) {
            open(existing)
            return
        }
        setLoading(true)
        statusLabel.textColor = UIColor(white: 0.7, alpha: 1)
        statusLabel.text = "Checking feed..."
        UpNextManager.shared.suspend()
        FeedParser.loadPodcast(feedUrl: url) { [weak self] result in
            UpNextManager.shared.resume()
            guard let self = self, self.view.window != nil else { return }
            self.setLoading(false)
            switch result {
            case .success(let feed):
                let podcast = Podcast.subscribe(feed.podcast)
                EpisodeListCache.store(feedUrl: podcast.feedUrl, episodes: feed.episodes)
                AutoEpisodeManager.shared.observe(feedURL: podcast.feedUrl, episodes: feed.episodes)
                self.open(podcast)
            case .failure(let error):
                self.showError(error.localizedDescription)
            }
        }
    }

    private func showError(_ message: String) {
        statusLabel.textColor = UIColor(red: 1, green: 0.5, blue: 0.5, alpha: 1)
        statusLabel.text = message
    }

    private func open(_ podcast: Podcast) {
        guard let navigation = navigationController else { return }
        var stack = navigation.viewControllers
        stack.removeLast()
        stack.append(EpisodeListVC(podcast: podcast))
        navigation.setViewControllers(stack, animated: true)
    }
}

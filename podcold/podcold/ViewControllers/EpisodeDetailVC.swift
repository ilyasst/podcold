import UIKit

class EpisodeDetailVC: UIViewController, UITextViewDelegate {
    private let episode: Episode
    private let podcast: Podcast
    private var downloadBtn: UIButton!
    private var queueBtn: UIButton!

    private static let purple = UIColor(red: 0.53, green: 0.26, blue: 0.73, alpha: 1)
    private static let red    = UIColor(red: 0.85, green: 0.25, blue: 0.25, alpha: 1)

    init(episode: Episode, podcast: Podcast) {
        self.episode = episode; self.podcast = podcast
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(self, selector: #selector(updateQueueButton), name: .playQueueChanged, object: nil)
        view.backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.14, alpha: 1)

        let w = UIScreen.main.bounds.width
        let scrollView = UIScrollView(frame: view.bounds)
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(scrollView)

        var y: CGFloat = 20

        let artSize: CGFloat = min(w - 40, 260)
        let artwork = AsyncImageView(frame: CGRect(x: (w - artSize) / 2, y: y, width: artSize, height: artSize))
        artwork.contentMode = .scaleAspectFill
        artwork.clipsToBounds = true
        artwork.layer.cornerRadius = 8
        artwork.layer.shouldRasterize = true
        artwork.layer.rasterizationScale = UIScreen.main.scale
        artwork.backgroundColor = UIColor(white: 0.15, alpha: 1)
        let imgUrl = episode.artworkUrl.isEmpty ? podcast.artworkUrl600 : episode.artworkUrl
        if !imgUrl.isEmpty { artwork.load(url: imgUrl) }
        scrollView.addSubview(artwork)
        y += artSize + 20

        let titleLabel = UILabel(frame: CGRect(x: 20, y: y, width: w - 40, height: 50))
        titleLabel.text = episode.title
        titleLabel.textColor = .white
        titleLabel.backgroundColor = .clear
        titleLabel.font = UIFont.boldSystemFont(ofSize: 15)
        titleLabel.numberOfLines = 2
        scrollView.addSubview(titleLabel)
        y += 54

        if !episode.author.isEmpty {
            let authorLabel = UILabel(frame: CGRect(x: 20, y: y, width: w - 40, height: 20))
            authorLabel.accessibilityIdentifier = "episode-author"
            authorLabel.text = "By " + episode.author
            authorLabel.textColor = UIColor(white: 0.75, alpha: 1)
            authorLabel.backgroundColor = .clear
            authorLabel.font = UIFont.systemFont(ofSize: 13)
            authorLabel.adjustsFontSizeToFitWidth = true
            scrollView.addSubview(authorLabel)
            y += 26
        }

        // The podcast name, not the publisher. Tappable when we know the feed —
        // episodes reached from Home/Downloads can carry a stub Podcast whose
        // feedUrl is empty, and there is no list to open for those.
        let showName = podcast.title.isEmpty ? episode.podcastTitle : podcast.title
        let canOpenList = !podcast.feedUrl.isEmpty
        // A UIButton, not a label with a tap recognizer: on iOS 6 a recognizer
        // on a scroll view subview fires alongside the buttons below it.
        let podcastBtn = UIButton(type: .custom)
        podcastBtn.frame = CGRect(x: 20, y: y, width: w - 40, height: 20)
        podcastBtn.contentHorizontalAlignment = .left
        podcastBtn.setTitle(showName, for: .normal)
        podcastBtn.setTitleColor(canOpenList ? EpisodeDetailVC.purple : UIColor(white: 0.55, alpha: 1),
                                 for: .normal)
        podcastBtn.titleLabel?.font = UIFont.systemFont(ofSize: 13)
        podcastBtn.isEnabled = canOpenList
        podcastBtn.addTarget(self, action: #selector(podcastTapped), for: .touchUpInside)
        scrollView.addSubview(podcastBtn)
        y += 32

        // Action buttons — one metric for all three: 20pt margins, 12pt gap,
        // so the two halves and the full-width row line up exactly.
        let btnH: CGFloat = 40
        let colW = (w - 52) / 2

        let playBtn = UIButton(type: .custom)
        playBtn.frame = CGRect(x: 20, y: y, width: colW, height: btnH)
        playBtn.setTitle("Play", for: .normal)
        playBtn.setTitleColor(.white, for: .normal)
        playBtn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 15)
        playBtn.backgroundColor = EpisodeDetailVC.purple
        playBtn.layer.cornerRadius = btnH / 2
        playBtn.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
        scrollView.addSubview(playBtn)

        queueBtn = UIButton(type: .custom)
        queueBtn.frame = CGRect(x: 32 + colW, y: y, width: colW, height: btnH)
        queueBtn.layer.cornerRadius = btnH / 2
        queueBtn.layer.borderWidth = 1
        queueBtn.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        queueBtn.addTarget(self, action: #selector(queueTapped), for: .touchUpInside)
        scrollView.addSubview(queueBtn)
        updateQueueButton()
        y += btnH + 10

        // One button cycling Download -> progress -> Remove Download, so the row is
        // never half-empty and there is no dead "Offline" button next to a Remove.
        downloadBtn = UIButton(type: .custom)
        downloadBtn.frame = CGRect(x: 20, y: y, width: w - 40, height: btnH)
        downloadBtn.layer.cornerRadius = btnH / 2
        downloadBtn.layer.borderWidth = 1
        downloadBtn.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        downloadBtn.addTarget(self, action: #selector(downloadTapped), for: .touchUpInside)
        scrollView.addSubview(downloadBtn)

        updateDownloadButton(progress: nil)
        y += btnH + 12

        if !episode.summary.isEmpty {
            let sep = UIView(frame: CGRect(x: 20, y: y, width: w - 40, height: 1))
            sep.backgroundColor = UIColor(white: 0.2, alpha: 1)
            scrollView.addSubview(sep)
            y += 12

            if #available(iOS 7.0, *) {
                let notes = UITextView(frame: CGRect(x: 20, y: y, width: w - 40, height: 1))
                notes.accessibilityIdentifier = "episode-notes"
                notes.backgroundColor = .clear
                notes.isEditable = false
                notes.isSelectable = true
                notes.isScrollEnabled = false
                notes.textContainerInset = .zero
                notes.textContainer.lineFragmentPadding = 0
                notes.dataDetectorTypes = .link
                notes.linkTextAttributes = [.foregroundColor: EpisodeDetailVC.purple,
                                            .underlineStyle: NSUnderlineStyle.single.rawValue]
                notes.delegate = self
                scrollView.addSubview(notes)

                let labelY = y
                let capturedW = w
                let summary = episode.summary
                let feedURL = podcast.feedUrl
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 13), .foregroundColor: UIColor(white: 0.75, alpha: 1)]
                DispatchQueue(label: "com.podcold.misc").async {
                    let text = NSMutableAttributedString(attributedString: EpisodeDetailVC.renderNotes(summary, baseURL: feedURL))
                    text.addAttributes(attributes, range: NSRange(location: 0, length: text.length))
                    DispatchQueue.main.async { [weak notes, weak scrollView] in
                        guard let notes = notes, let sv = scrollView else { return }
                        notes.attributedText = text
                        let size = notes.sizeThatFits(CGSize(width: capturedW - 40, height: CGFloat.greatestFiniteMagnitude))
                        notes.frame.size.height = ceil(size.height)
                        sv.contentSize = CGSize(width: capturedW, height: labelY + notes.frame.height + 16 + 70)
                    }
                }
            } else {
                let notes = LegacyEpisodeNotesView(html: episode.summary, baseURL: podcast.feedUrl, width: w - 40)
                notes.frame.origin = CGPoint(x: 20, y: y)
                scrollView.addSubview(notes)
                y += notes.bounds.height
            }
        }

        scrollView.contentSize = CGSize(width: w, height: y + 70)
    }

    private func updateDownloadButton(progress: Float?) {
        if let p = progress {
            downloadBtn.setTitle("\(Int(p * 100))%", for: .normal)
            downloadBtn.setTitleColor(UIColor(white: 0.6, alpha: 1), for: .normal)
            downloadBtn.layer.borderColor = UIColor(white: 0.3, alpha: 1).cgColor
            downloadBtn.isEnabled = false
        } else if episode.localPath() != nil {
            downloadBtn.setTitle("Remove Download", for: .normal)
            downloadBtn.setTitleColor(EpisodeDetailVC.red, for: .normal)
            downloadBtn.layer.borderColor = EpisodeDetailVC.red.cgColor
            downloadBtn.isEnabled = true
        } else {
            downloadBtn.setTitle("Download", for: .normal)
            downloadBtn.setTitleColor(EpisodeDetailVC.purple, for: .normal)
            downloadBtn.layer.borderColor = EpisodeDetailVC.purple.cgColor
            downloadBtn.isEnabled = true
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func updateQueueButton() {
        guard queueBtn != nil else { return }
        let purple = EpisodeDetailVC.purple
        if PlayQueue.shared.contains(guid: episode.guid) {
            queueBtn.setTitle("In playlist", for: .normal)
            queueBtn.setTitleColor(UIColor(white: 0.45, alpha: 1), for: .normal)
            queueBtn.layer.borderColor = UIColor(white: 0.25, alpha: 1).cgColor
        } else {
            queueBtn.setTitle("+ Playlist", for: .normal)
            queueBtn.setTitleColor(purple, for: .normal)
            queueBtn.layer.borderColor = purple.cgColor
        }
    }

    @objc private func queueTapped() {
        if PlayQueue.shared.contains(guid: episode.guid) {
            PlayQueue.shared.remove(guid: episode.guid)
        } else {
            if !PlayQueue.shared.add(episode) { EpisodePlaylistActions.showCannotAdd(episode) }
        }
        updateQueueButton()
    }

    // Same button in all three states — the title says which one is live
    @objc private func downloadTapped() {
        if let path = episode.localPath() {
            // AVPlayer is reading this exact file — see DownloadsVC's swipe-delete.
            guard AudioPlayer.shared.currentEpisode?.guid != episode.guid else {
                let a = UIAlertView()
                a.title   = "Still Playing"
                a.message = "Close the player before deleting this download."
                a.addButton(withTitle: "OK")
                a.show()
                return
            }
            try? FileManager.default.removeItem(atPath: path)
            Episode.removeFromDownloads(guid: episode.guid)
            updateDownloadButton(progress: nil)
            return
        }
        updateDownloadButton(progress: 0)
        EpisodeDownloader.download(episode: episode,
            progress: { [weak self] p in self?.updateDownloadButton(progress: p) },
            completion: { [weak self] _ in self?.updateDownloadButton(progress: nil) })
    }

    // Show notes are HTML with no literal newlines — the paragraph structure
    // lives entirely in the <p>/<br>/<li> tags. Dropping every tag therefore
    // collapsed the whole description into one run-on block, so block-level
    // tags are turned into line breaks before the rest are discarded.
    // Keep labels and URL attributes together while decoding entities and
    // normalizing paragraphs. No HTML, JavaScript or remote content is executed.
    static func renderNotes(_ html: String, baseURL: String) -> NSAttributedString {
        let output = NSMutableAttributedString(string: "")
        var text = "", tag = "", inTag = false
        var quote: Character?
        var link: URL?
        func flush() {
            guard !text.isEmpty else { return }
            var attributes: [NSAttributedString.Key: Any] = [:]
            if let target = link { attributes[NSAttributedString.Key("NSLink")] = target }
            output.append(NSAttributedString(string: decodeEntities(text), attributes: attributes))
            text = ""
        }
        for c in html {
            if !inTag {
                if c == "<" { flush(); inTag = true; tag = ""; quote = nil }
                else { text.append(c) }
            } else if let activeQuote = quote {
                tag.append(c)
                if c == activeQuote { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c; tag.append(c)
            } else if c == ">" {
                inTag = false
                let name = tag.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: .whitespacesAndNewlines).first ?? ""
                if name == "a" { link = anchorURL(tag, baseURL: baseURL) }
                else if name == "/a" { link = nil }
                output.append(NSAttributedString(string: breakFor(tag: tag)))
            } else { tag.append(c) }
        }
        if inTag { text += "<" + tag }
        flush()
        // Replacing only whitespace preserves link ranges, including UTF-16
        // offsets around emoji and typographic punctuation.
        for (pattern, replacement) in [("\\r\\n?", "\n"), ("(?m)^[ \\t]+|[ \\t]+$", ""),
                                       ("\n{3,}", "\n\n"), ("\\A\\s+|\\s+\\z", "")] {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let matches = regex.matches(in: output.string, options: [], range: NSRange(location: 0, length: output.length))
                for match in matches.reversed() { output.replaceCharacters(in: match.range, with: replacement) }
            }
        }
        return output
    }

    static func noteURL(_ raw: String, baseURL: String = "") -> URL? {
        guard let url = URL(string: decodeEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines),
                            relativeTo: URL(string: baseURL))?.absoluteURL,
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    private static func anchorURL(_ tag: String, baseURL: String) -> URL? {
        let pattern = "\\s+([\\w:-]+)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'=<>`]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let source = tag as NSString
        for match in regex.matches(in: tag, options: [], range: NSRange(location: 0, length: source.length)) {
            guard source.substring(with: match.range(at: 1)).lowercased() == "href" else { continue }
            for group in 2..<match.numberOfRanges {
                let range = match.range(at: group)
                if range.location != NSNotFound { return noteURL(source.substring(with: range), baseURL: baseURL) }
            }
        }
        return nil
    }

    // The original iOS 7 delegate method: the interaction-argument variant is iOS 10+.
    func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange) -> Bool {
        guard let url = EpisodeDetailVC.noteURL(URL.absoluteString),
              UIApplication.shared.openURL(url) else { return false }
        return false  // Safari handles the URL; UITextView must not open it a second time.
    }

    // "" for inline tags (<a>, <em>, <strong>…), a line break for block ones.
    private static func breakFor(tag: String) -> String {
        var t = tag.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let closing = t.hasPrefix("/")
        if closing { t.removeFirst() }
        // Stop at the first attribute or at a self-closing slash: "br /" -> "br"
        let name = t.components(separatedBy: CharacterSet(charactersIn: " \t\n\r/")).first ?? ""
        switch name {
        case "br":
            return "\n"
        case "li":
            return closing ? "" : "\n\u{2022} "
        case "p", "div", "blockquote", "pre", "ul", "ol", "table", "tr",
             "h1", "h2", "h3", "h4", "h5", "h6":
            return "\n\n"
        default:
            return ""
        }
    }

    private static func decodeEntities(_ s: String) -> String {
        var out = decodeNumericEntities(s)
        // &amp; must come last, or "&amp;lt;" would wrongly end up as "<"
        let named = [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
                     ("&apos;", "'"), ("&nbsp;", " "),
                     ("&hellip;", "\u{2026}"), ("&mdash;", "\u{2014}"),
                     ("&ndash;", "\u{2013}"),
                     ("&rsquo;", "\u{2019}"), ("&lsquo;", "\u{2018}"),
                     ("&rdquo;", "\u{201D}"), ("&ldquo;", "\u{201C}"),
                     ("&amp;", "&")]
        for (entity, replacement) in named {
            out = out.replacingOccurrences(of: entity, with: replacement)
        }
        return out
    }

    // Feeds lean heavily on &#8217; / &#x2019; for typographic punctuation —
    // undecoded these showed up as literal noise mid-sentence.
    private static func decodeNumericEntities(_ s: String) -> String {
        let parts = s.components(separatedBy: "&#")
        guard parts.count > 1 else { return s }
        var out = parts[0]
        for part in parts.dropFirst() {
            guard let semi = part.firstIndex(of: ";") else { out += "&#" + part; continue }
            var body = String(part[part.startIndex..<semi])
            let rest = String(part[part.index(after: semi)...])
            let value: UInt32?
            if body.hasPrefix("x") || body.hasPrefix("X") {
                body.removeFirst()
                value = UInt32(body, radix: 16)
            } else {
                value = UInt32(body, radix: 10)
            }
            if let v = value, let scalar = UnicodeScalar(v) {
                out += String(Character(scalar)) + rest
            } else {
                out += "&#" + part
            }
        }
        return out
    }

    // Coming from the podcast's own list, pushing another one would stack
    // List -> Detail -> List and leave Back pointing at the episode we just
    // left. Go back to the existing screen when there is one.
    @objc private func podcastTapped() {
        guard let nav = navigationController else { return }
        if let existing = nav.viewControllers.reversed().first(where: {
            ($0 as? EpisodeListVC)?.podcast.feedUrl == podcast.feedUrl
        }) {
            nav.popToViewController(existing, animated: true)
            return
        }
        nav.pushViewController(EpisodeListVC(podcast: podcast), animated: true)
    }

    @objc private func playTapped() {
        // Playing it now takes it out of "up next"
        PlayQueue.shared.remove(guid: episode.guid)
        AudioPlayer.shared.play(episode: episode)
        navigationController?.pushViewController(NowPlayingVC(), animated: true)
    }
}

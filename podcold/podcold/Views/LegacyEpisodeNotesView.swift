import UIKit

// iOS 6 has no selectable UITextView or custom attributed-link interaction.
// Keep the same parsed notes and expose their web links as native buttons.
class LegacyEpisodeNotesView: UIView {
    private var links: [URL] = []

    init(html: String, baseURL: String, width: CGFloat) {
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: 0))
        accessibilityIdentifier = "episode-notes-legacy"
        let notes = EpisodeDetailVC.renderNotes(html, baseURL: baseURL)
        var y: CGFloat = 0
        notes.enumerateAttributes(in: NSRange(location: 0, length: notes.length), options: []) { attributes, range, _ in
            let text = (notes.string as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text != "|" else { return }
            if let url = attributes[NSAttributedString.Key("NSLink")] as? URL {
                let button = UIButton(type: .custom)
                button.frame = CGRect(x: 0, y: y, width: width, height: 40)
                button.setTitle(text, for: .normal)
                button.titleLabel?.font = UIFont.systemFont(ofSize: 14)
                button.titleLabel?.numberOfLines = 2
                button.contentHorizontalAlignment = .left
                button.setTitleColor(UIColor(red: 0.75, green: 0.58, blue: 0.9, alpha: 1), for: .normal)
                button.tag = links.count
                links.append(url)
                button.addTarget(self, action: #selector(openLink(_:)), for: .touchUpInside)
                addSubview(button)
                y += 44
            } else {
                let label = UILabel()
                label.text = text
                label.numberOfLines = 0
                label.font = UIFont.systemFont(ofSize: 13)
                label.textColor = UIColor(white: 0.75, alpha: 1)
                label.backgroundColor = .clear
                let size = label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
                label.frame = CGRect(x: 0, y: y, width: width, height: ceil(size.height))
                addSubview(label)
                y += ceil(size.height) + 10
            }
        }
        frame.size.height = y
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func openLink(_ sender: UIButton) {
        guard sender.tag < links.count,
              let url = EpisodeDetailVC.noteURL(links[sender.tag].absoluteString) else { return }
        UIApplication.shared.openURL(url)
    }
}

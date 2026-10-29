import UIKit

class PlaylistSettingsVC: UITableViewController {
    init() { super.init(style: .grouped) }
    // iOS 6's UITableViewController.init(style:) calls this initializer on self.
    override init(nibName: String?, bundle: Bundle?) { super.init(nibName: nibName, bundle: bundle) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Playlist Options"
        tableView.backgroundColor = UIColor(red: 0.14, green: 0.14, blue: 0.18, alpha: 1)
        tableView.rowHeight = 54
        tableView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 60, right: 0)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { return 3 }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { return "Automatic adding" }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return "New episodes are added when subscribed feeds refresh. New downloads are added when a download finishes, including manual downloads. The switches work independently and apply to future arrivals. Played or currently playing episodes are skipped.\n\nThe limit counts episodes waiting to play. When full, up to 200 automatic arrivals wait for a free slot. Lowering the limit keeps existing entries. Removing an episode keeps its download."
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.backgroundColor = UIColor(red: 0.18, green: 0.18, blue: 0.22, alpha: 1)
        cell.textLabel?.textColor = .white
        cell.textLabel?.backgroundColor = .clear
        cell.textLabel?.font = UIFont.systemFont(ofSize: 14)
        cell.detailTextLabel?.textColor = UIColor(white: 0.6, alpha: 1)
        cell.detailTextLabel?.backgroundColor = .clear
        cell.selectionStyle = .none
        if indexPath.row < 2 {
            let download = indexPath.row == 1
            cell.textLabel?.text = download ? "Add new downloads" : "Add new episodes"
            let toggle = UISwitch()
            toggle.isOn = download ? PlayQueue.addDownloads : AutoEpisodeManager.queueEnabled
            toggle.accessibilityIdentifier = download ? "playlist-add-downloads" : "auto-queue"
            toggle.addTarget(self, action: download ? #selector(downloadsChanged(_:)) : #selector(arrivalsChanged(_:)), for: .valueChanged)
            cell.accessoryView = toggle
        } else {
            cell.textLabel?.text = "Maximum episodes"
            cell.detailTextLabel?.text = "\(PlayQueue.maximumSize)"
            let stepper = UIStepper()
            stepper.minimumValue = Double(PlayQueue.limitRange.lowerBound)
            stepper.maximumValue = Double(PlayQueue.limitRange.upperBound)
            stepper.value = Double(PlayQueue.maximumSize)
            stepper.accessibilityIdentifier = "playlist-size-limit"
            stepper.addTarget(self, action: #selector(limitChanged(_:)), for: .valueChanged)
            cell.accessoryView = stepper
        }
        return cell
    }

    @objc private func downloadsChanged(_ sender: UISwitch) {
        PlayQueue.addDownloads = sender.isOn
        PlayQueue.shared.fillAvailableSlots()
    }
    @objc private func arrivalsChanged(_ sender: UISwitch) {
        AutoEpisodeManager.queueEnabled = sender.isOn
        PlayQueue.shared.fillAvailableSlots()
    }
    @objc private func limitChanged(_ sender: UIStepper) {
        PlayQueue.maximumSize = Int(sender.value)
        tableView.cellForRow(at: IndexPath(row: 2, section: 0))?.detailTextLabel?.text = "\(PlayQueue.maximumSize)"
        PlayQueue.shared.fillAvailableSlots()
    }
}

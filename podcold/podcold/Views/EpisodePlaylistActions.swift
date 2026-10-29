import UIKit

// Retained by its screen until the iOS 6/7 action-sheet callback completes.
class EpisodePlaylistActions: NSObject, UIActionSheetDelegate {
    private var episode: Episode?
    private var removing = false

    func show(episode: Episode, in view: UIView) {
        self.episode = episode
        removing = PlayQueue.shared.contains(guid: episode.guid)
        let sheet = UIActionSheet()
        sheet.title = episode.title
        sheet.delegate = self
        sheet.addButton(withTitle: removing ? "Remove from playlist" : "Add to playlist")
        sheet.addButton(withTitle: "Cancel")
        sheet.cancelButtonIndex = 1
        sheet.show(in: view)
    }

    func actionSheet(_ actionSheet: UIActionSheet, clickedButtonAt buttonIndex: Int) {
        guard buttonIndex == 0, let ep = episode else { episode = nil; return }
        if removing { PlayQueue.shared.remove(guid: ep.guid) }
        else if !PlayQueue.shared.add(ep) { EpisodePlaylistActions.showCannotAdd(ep) }
        episode = nil
    }

    static func showCannotAdd(_ episode: Episode) {
        let alert = UIAlertView()
        if AudioPlayer.shared.currentEpisode?.guid == episode.guid {
            alert.title = "Already playing"
            alert.message = "This episode is playing now. The playlist holds what comes next."
        } else {
            alert.title = "Playlist is full"
            alert.message = "Remove an episode or increase Maximum episodes in Playlist Options."
        }
        alert.addButton(withTitle: "OK")
        alert.show()
    }
}

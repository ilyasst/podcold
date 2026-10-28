#if PODCOLD_DEVICE_TESTING
import UIKit

// Compiled only for opt-in device tests. It uses real UIKit controls and the
// normal search flow; it never subscribes to a show or changes listening state.
enum DeviceSmokeTest {
    private static var checks: [String: Any] = [:]
    private static var navigation: UINavigationController?
    private static var attempts = 0

    private static func descendants(_ view: UIView) -> [UIView] {
        return [view] + view.subviews.flatMap { descendants($0) }
    }

    static func run(navigation: UINavigationController) {
        self.navigation = navigation
        checks = [:]
        attempts = 0
        let prefix = "--podcold-test-token="
        if let token = CommandLine.arguments.first(where: { $0.hasPrefix(prefix) }) {
            checks["run_token"] = String(token.dropFirst(prefix.count))
        }
        guard let home = navigation.topViewController as? HomeVC else {
            finish(error: "Home screen did not open")
            return
        }
        let views = descendants(home.view)
        checks["home_content_visible"] = views.contains {
            ($0 as? UILabel)?.text == "MY PODCASTS"
        }
        if let button = views.compactMap({ $0 as? UIButton }).first(where: {
            $0.title(for: .normal) == "Search Podcasts"
        }) {
            button.sendActions(for: .touchUpInside)
        } else if let item = home.navigationItem.rightBarButtonItems?.first(where: {
            $0.action.map { NSStringFromSelector($0) == "openSearch" } ?? false
        }), let action = item.action {
            UIApplication.shared.sendAction(action, to: item.target, from: item, for: nil)
        } else {
            finish(error: "Search action missing")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { inspectSearch() }
    }

    private static func inspectSearch() {
        guard let navigation = navigation,
              let searchVC = navigation.topViewController as? SearchVC,
              let search = descendants(searchVC.view).compactMap({ $0 as? UISearchBar }).first,
              let window = search.window else {
            finish(error: "Search action did not open a search field")
            return
        }
        let frame = search.convert(search.bounds, to: window)
        let bar = navigation.navigationBar.convert(navigation.navigationBar.bounds, to: window)
        checks["search_below_navigation"] = frame.minY >= bar.maxY - 1
        checks["search_visible"] = !search.isHidden && search.alpha > 0 && frame.width > 100 && frame.height >= 40
        checks["keyboard_focused"] = descendants(search).contains { $0.isFirstResponder }
        checks["search_y"] = Double(frame.minY)
        checks["navigation_bottom"] = Double(bar.maxY)
        emit(stage: "search_field")

        // Leave enough time for the host runner to capture the keyboard screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            search.text = "audio drama"
            search.delegate?.searchBarSearchButtonClicked?(search)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { inspectResults() }
        }
    }

    private static func inspectResults() {
        guard let searchVC = navigation?.topViewController as? SearchVC,
              let table = descendants(searchVC.view).compactMap({ $0 as? UITableView }).first else {
            finish(error: "Search results table missing")
            return
        }
        let count = table.dataSource?.tableView(table, numberOfRowsInSection: 0) ?? 0
        if count > 0 {
            checks["search_result_count"] = count
            checks["search_returns_results"] = true
            finish(error: nil)
        } else if attempts < 12 {
            attempts += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { inspectResults() }
        } else {
            checks["search_returns_results"] = false
            finish(error: "Search returned no results within 26 seconds")
        }
    }

    private static func finish(error: String?) {
        let required = ["home_content_visible", "search_below_navigation", "search_visible",
                        "keyboard_focused", "search_returns_results"]
        checks["passed"] = error == nil && required.allSatisfy { checks[$0] as? Bool == true }
        if let error = error { checks["error"] = error }
        emit(stage: "complete")
        navigation = nil
    }

    private static func emit(stage: String) {
        var report = checks
        report["stage"] = stage
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: []),
              let json = String(data: data, encoding: .utf8) else { return }
        NSLog("PODCOLD_DEVICE_TEST %@", json)
    }
}
#endif

import Foundation

/// clipper://show, search?q=, stack, new, settings, collect, pause, about
public enum URLAction: Equatable {
    case show, stack, new, settings, collect, pause, about, clear
    case search(String)

    public static func parse(_ url: URL) -> URLAction? {
        guard url.scheme == "clipper" else { return nil }
        switch url.host {
        case "show": return .show
        case "stack": return .stack
        case "new": return .new
        case "settings": return .settings
        case "collect": return .collect
        case "pause": return .pause
        case "about": return .about
        case "clear": return .clear
        case "search":
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value ?? ""
            return .search(q)
        default: return nil
        }
    }
}


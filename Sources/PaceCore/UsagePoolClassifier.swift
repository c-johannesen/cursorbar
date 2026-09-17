import Foundation

public enum UsagePool: Sendable, Equatable {
    case auto
    case api
}

/// Maps a Cursor usage-event `model` to Auto vs API.
/// Probe 2026-08-21: events have no pool tag (`kind` is always included-in-plan).
/// Auto = first-party (`composer*`, `cursor-*`, `default`, `auto*`); else named API.
public enum UsagePoolClassifier {
    public static func pool(forModel model: String?) -> UsagePool {
        let name = (model ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if name.hasPrefix("composer")
            || name.hasPrefix("cursor-")
            || name == "default"
            || name.hasPrefix("auto")
        {
            return .auto
        }
        return .api
    }
}

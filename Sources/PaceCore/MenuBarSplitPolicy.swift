public enum MenuBarSplitPolicy {
    /// Same yellow floor as `UsageStore.poolDailyStatusColor`.
    public static let warningThreshold: Double = 70

    public struct Prefs: Equatable {
        public var showDaily: Bool
        public var showAuto: Bool
        public var showApi: Bool

        public init(showDaily: Bool, showAuto: Bool, showApi: Bool) {
            self.showDaily = showDaily
            self.showAuto = showAuto
            self.showApi = showApi
        }
    }

    public struct Effective: Equatable {
        public var showDaily: Bool
        public var showAuto: Bool
        public var showApi: Bool
        public var isOverride: Bool

        public init(showDaily: Bool, showAuto: Bool, showApi: Bool, isOverride: Bool) {
            self.showDaily = showDaily
            self.showAuto = showAuto
            self.showApi = showApi
            self.isOverride = isOverride
        }
    }

    public static func isPoolWarning(percent: Double?, depleted: Bool) -> Bool {
        if depleted { return true }
        guard let percent else { return false }
        return percent >= warningThreshold
    }

    public static func effectiveVisibility(
        prefs: Prefs,
        autoIsWarning: Bool,
        apiIsWarning: Bool,
        autoSplitEnabled: Bool = true
    ) -> Effective {
        let shouldOverride = autoSplitEnabled && prefs.showDaily && (autoIsWarning || apiIsWarning)
        return Effective(
            showDaily: prefs.showDaily && !shouldOverride,
            showAuto: prefs.showAuto || shouldOverride,
            showApi: prefs.showApi || shouldOverride,
            isOverride: shouldOverride
        )
    }
}

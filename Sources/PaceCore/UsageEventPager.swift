import Foundation

public enum UsageEventPageDecision: Equatable, Sendable {
    case done
    case fetchNext
    case incomplete
}

public enum UsageEventPager {
    /// Stop and discard a partial sum past this page instead of treating it as the full day.
    public static let safetyPageLimit = 100

    public static func decision(
        page: Int,
        pageSize: Int,
        eventsOnPage: Int,
        totalCount: Int
    ) -> UsageEventPageDecision {
        if eventsOnPage <= 0 || page * pageSize >= totalCount {
            return .done
        }
        if page >= safetyPageLimit {
            return .incomplete
        }
        return .fetchNext
    }
}

import Foundation
import PaceCore

enum CursorAPIError: Error, LocalizedError {
    case notAuthenticated
    case invalidResponse
    case httpError(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            "Not authenticated. Please log in to Cursor."
        case .invalidResponse:
            "Could not parse usage data from Cursor."
        case .httpError(let statusCode):
            "Cursor API returned HTTP \(statusCode)."
        }
    }
}

struct UsageBreakdown: Decodable, Sendable {
    let included: Int?
    let bonus: Int?
    let total: Int?
}

struct PlanUsage: Decodable, Sendable {
    let enabled: Bool?
    let used: Int?
    let limit: Int?
    let remaining: Int?
    let breakdown: UsageBreakdown?
    let autoPercentUsed: Double?
    let apiPercentUsed: Double?
    let totalPercentUsed: Double?
}

struct OnDemandUsage: Decodable, Sendable {
    let enabled: Bool?
    let used: Int?
    let limit: Int?
    let remaining: Int?

    var isEnabled: Bool { enabled ?? false }
    var usedCents: Int { used ?? 0 }
}

/// Spend on token-based Enterprise contracts that omit `plan`.
struct OverallUsage: Decodable, Sendable {
    let enabled: Bool?
    let used: Int?
    let limit: Int?
    let remaining: Int?
}

struct IndividualUsage: Decodable, Sendable {
    let plan: PlanUsage?
    let onDemand: OnDemandUsage?
    let overall: OverallUsage?
}

struct TeamUsage: Decodable, Sendable {
    let onDemand: OnDemandUsage?
}

struct UsageSummary: Decodable, Sendable {
    let billingCycleStart: String?
    let billingCycleEnd: String?
    let membershipType: String?
    let limitType: String?
    let isUnlimited: Bool?
    let autoModelSelectedDisplayMessage: String?
    let namedModelSelectedDisplayMessage: String?
    let individualUsage: IndividualUsage?
    let teamUsage: TeamUsage?
}

struct UsageEventsPage: Decodable, Sendable {
    let totalUsageEventsCount: Int
    let usageEventsDisplay: [UsageEvent]
}

struct UsageEvent: Decodable, Sendable {
    let model: String?
    let chargedCents: Double?
    let tokenUsage: TokenUsage?

    struct TokenUsage: Decodable, Sendable {
        let totalCents: Double?
    }

    var costCents: Double {
        chargedCents ?? tokenUsage?.totalCents ?? 0
    }
}

struct TodaySpend: Sendable, Equatable {
    var totalCents: Int
    var autoCents: Int
    var apiCents: Int
}

enum CursorAPI {
    private static let usageSummaryURL = URL(string: "https://cursor.com/api/usage-summary")!
    private static let usageEventsURL = URL(string: "https://cursor.com/api/dashboard/get-filtered-usage-events")!

    static func fetchUsageSummary() async throws -> UsageSummary {
        var credentials = try TokenProvider.loadSessionCredentials()

        do {
            return try await requestUsageSummary(credentials: credentials)
        } catch CursorAPIError.notAuthenticated {
            credentials = try TokenProvider.loadSessionCredentials()
            return try await requestUsageSummary(credentials: credentials)
        }
    }

    /// Sums usage events in today's Daily window, split Auto vs API by model.
    /// Starts at local midnight, or at `cycleStart` when the billing cycle reset later the same day.
    static func fetchTodaySpend(cycleStart: Date? = nil) async throws -> TodaySpend {
        var credentials = try TokenProvider.loadSessionCredentials()

        do {
            return try await requestTodaySpend(credentials: credentials, cycleStart: cycleStart)
        } catch CursorAPIError.notAuthenticated {
            credentials = try TokenProvider.loadSessionCredentials()
            return try await requestTodaySpend(credentials: credentials, cycleStart: cycleStart)
        }
    }

    private static func todaySpendWindowStart(
        now: Date = Date(),
        cycleStart: Date?,
        calendar: Calendar = .current
    ) -> Date {
        let midnight = calendar.startOfDay(for: now)
        guard let cycleStart else { return midnight }
        return max(midnight, cycleStart)
    }

    private static func requestTodaySpend(
        credentials: SessionCredentials,
        cycleStart: Date?
    ) async throws -> TodaySpend {
        let windowStart = todaySpendWindowStart(cycleStart: cycleStart)
        let startMs = String(Int(windowStart.timeIntervalSince1970 * 1000))
        let endMs = String(Int(Date().timeIntervalSince1970 * 1000))

        let pageSize = 100
        let maxPages = 10
        var autoCents = 0.0
        var apiCents = 0.0
        var page = 1

        while page <= maxPages {
            let result = try await requestUsageEventsPage(
                credentials: credentials,
                startMs: startMs,
                endMs: endMs,
                page: page,
                pageSize: pageSize
            )
            for event in result.usageEventsDisplay {
                switch UsagePoolClassifier.pool(forModel: event.model) {
                case .auto:
                    autoCents += event.costCents
                case .api:
                    apiCents += event.costCents
                }
            }

            if page * pageSize >= result.totalUsageEventsCount || result.usageEventsDisplay.isEmpty {
                break
            }
            page += 1
        }

        let auto = Int(autoCents.rounded())
        let api = Int(apiCents.rounded())
        return TodaySpend(totalCents: auto + api, autoCents: auto, apiCents: api)
    }

    private static func requestUsageEventsPage(
        credentials: SessionCredentials,
        startMs: String,
        endMs: String,
        page: Int,
        pageSize: Int
    ) async throws -> UsageEventsPage {
        var request = URLRequest(url: usageEventsURL)
        request.httpMethod = "POST"
        request.setValue("WorkosCursorSessionToken=\(credentials.cookieValue)", forHTTPHeaderField: "Cookie")
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "startDate": startMs,
            "endDate": endMs,
            "page": page,
            "pageSize": pageSize,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CursorAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            throw CursorAPIError.notAuthenticated
        default:
            throw CursorAPIError.httpError(statusCode: httpResponse.statusCode)
        }

        do {
            return try JSONDecoder().decode(UsageEventsPage.self, from: data)
        } catch {
            throw CursorAPIError.invalidResponse
        }
    }

    private static func requestUsageSummary(credentials: SessionCredentials) async throws -> UsageSummary {
        var request = URLRequest(url: usageSummaryURL)
        request.httpMethod = "GET"
        request.setValue("WorkosCursorSessionToken=\(credentials.cookieValue)", forHTTPHeaderField: "Cookie")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CursorAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            throw CursorAPIError.notAuthenticated
        default:
            throw CursorAPIError.httpError(statusCode: httpResponse.statusCode)
        }

        do {
            let summary = try JSONDecoder().decode(UsageSummary.self, from: data)
            guard summary.hasDisplayableUsage else {
                throw CursorAPIError.invalidResponse
            }
            return summary
        } catch {
            throw CursorAPIError.invalidResponse
        }
    }
}

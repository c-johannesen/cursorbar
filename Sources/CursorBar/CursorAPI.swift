import Foundation

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
    let included: Int
    let bonus: Int
    let total: Int
}

struct PlanUsage: Decodable, Sendable {
    let enabled: Bool
    let used: Int
    let limit: Int
    let remaining: Int
    let breakdown: UsageBreakdown
    let autoPercentUsed: Double
    let apiPercentUsed: Double
    let totalPercentUsed: Double
}

struct OnDemandUsage: Decodable, Sendable {
    let enabled: Bool
    let used: Int
    let limit: Int?
    let remaining: Int?
}

struct IndividualUsage: Decodable, Sendable {
    let plan: PlanUsage
    let onDemand: OnDemandUsage
}

struct UsageSummary: Decodable, Sendable {
    let billingCycleStart: String
    let billingCycleEnd: String
    let membershipType: String
    let limitType: String
    let isUnlimited: Bool
    let individualUsage: IndividualUsage
}

struct UsageEventsPage: Decodable, Sendable {
    let totalUsageEventsCount: Int
    let usageEventsDisplay: [UsageEvent]
}

struct UsageEvent: Decodable, Sendable {
    let chargedCents: Double?
    let tokenUsage: TokenUsage?

    struct TokenUsage: Decodable, Sendable {
        let totalCents: Double?
    }

    var costCents: Double {
        chargedCents ?? tokenUsage?.totalCents ?? 0
    }
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

    /// Sums the cost of all usage events since local midnight, in cents.
    static func fetchTodaySpendCents() async throws -> Int {
        var credentials = try TokenProvider.loadSessionCredentials()

        do {
            return try await requestTodaySpendCents(credentials: credentials)
        } catch CursorAPIError.notAuthenticated {
            credentials = try TokenProvider.loadSessionCredentials()
            return try await requestTodaySpendCents(credentials: credentials)
        }
    }

    private static func requestTodaySpendCents(credentials: SessionCredentials) async throws -> Int {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let startMs = String(Int(startOfDay.timeIntervalSince1970 * 1000))
        let endMs = String(Int(Date().timeIntervalSince1970 * 1000))

        let pageSize = 100
        let maxPages = 10
        var totalCents = 0.0
        var page = 1

        while page <= maxPages {
            let result = try await requestUsageEventsPage(
                credentials: credentials,
                startMs: startMs,
                endMs: endMs,
                page: page,
                pageSize: pageSize
            )
            totalCents += result.usageEventsDisplay.reduce(0) { $0 + $1.costCents }

            if page * pageSize >= result.totalUsageEventsCount || result.usageEventsDisplay.isEmpty {
                break
            }
            page += 1
        }

        return Int(totalCents.rounded())
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
            return try JSONDecoder().decode(UsageSummary.self, from: data)
        } catch {
            throw CursorAPIError.invalidResponse
        }
    }
}

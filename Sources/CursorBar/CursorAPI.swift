import Foundation
import PaceCore

enum CursorAPIError: Error, LocalizedError {
    case notAuthenticated
    case invalidResponse
    case httpError(statusCode: Int)
    case incompleteEvents

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            "Not authenticated. Please log in to Cursor."
        case .invalidResponse:
            "Could not parse usage data from Cursor."
        case .httpError(let statusCode):
            "Cursor API returned HTTP \(statusCode)."
        case .incompleteEvents:
            "Usage events were cut off before the day was fully counted."
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

struct PublicProfileTokens: Equatable, Sendable {
    let handle: String
    let periodTokens: Int
    let totalTokens: Int
}

enum CursorAPI {
    private static let usageSummaryURL = URL(string: "https://cursor.com/api/usage-summary")!
    private static let usageEventsURL = URL(string: "https://cursor.com/api/dashboard/get-filtered-usage-events")!
    private static let userProfileURL = URL(string: "https://cursor.com/api/dashboard/get-user-profile")!

    static func fetchUsageSummary() async throws -> UsageSummary {
        var credentials = try TokenProvider.loadSessionCredentials()

        do {
            return try await requestUsageSummary(credentials: credentials)
        } catch CursorAPIError.notAuthenticated {
            credentials = try TokenProvider.loadSessionCredentials()
            return try await requestUsageSummary(credentials: credentials)
        }
    }

    /// Token totals from the public profile heatmap (`cursor.com/@handle`).
    static func fetchPublicProfileTokens(periodStart: Date?) async throws -> PublicProfileTokens {
        var credentials = try TokenProvider.loadSessionCredentials()
        do {
            return try await requestPublicProfileTokens(credentials: credentials, periodStart: periodStart)
        } catch CursorAPIError.notAuthenticated {
            credentials = try TokenProvider.loadSessionCredentials()
            return try await requestPublicProfileTokens(credentials: credentials, periodStart: periodStart)
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
        var autoCents = 0.0
        var apiCents = 0.0
        var page = 1

        pageLoop: while true {
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

            switch UsageEventPager.decision(
                page: page,
                pageSize: pageSize,
                eventsOnPage: result.usageEventsDisplay.count,
                totalCount: result.totalUsageEventsCount
            ) {
            case .done:
                break pageLoop
            case .fetchNext:
                page += 1
            case .incomplete:
                throw CursorAPIError.incompleteEvents
            }
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

    private static func requestPublicProfileTokens(
        credentials: SessionCredentials,
        periodStart: Date?
    ) async throws -> PublicProfileTokens {
        let handle = try await requestProfileHandle(credentials: credentials)
        let daily = try await requestProfileActivityCounts(credentials: credentials, handle: handle)
        let totalTokens = daily.reduce(0) { $0 + $1.count }
        let periodStartDay = periodStart.map(utcDateString)
        let periodTokens = daily.reduce(0) { sum, day in
            guard let periodStartDay, day.date >= periodStartDay else { return sum }
            return sum + day.count
        }
        return PublicProfileTokens(handle: handle, periodTokens: periodTokens, totalTokens: totalTokens)
    }

    private static func requestProfileHandle(credentials: SessionCredentials) async throws -> String {
        var request = URLRequest(url: userProfileURL)
        request.httpMethod = "POST"
        request.setValue("WorkosCursorSessionToken=\(credentials.cookieValue)", forHTTPHeaderField: "Cookie")
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

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

        struct UserProfileResponse: Decodable {
            struct Profile: Decodable {
                let handle: String?
            }

            let profile: Profile?
        }

        guard let handle = try? JSONDecoder().decode(UserProfileResponse.self, from: data).profile?.handle,
              !handle.isEmpty
        else {
            throw CursorAPIError.invalidResponse
        }
        return handle
    }

    private static func requestProfileActivityCounts(
        credentials _: SessionCredentials,
        handle: String
    ) async throws -> [ProfileActivityDay] {
        guard let url = URL(string: "https://cursor.com/@\(handle)") else {
            throw CursorAPIError.invalidResponse
        }

        // This page is public. Sending the dashboard session cookie makes
        // cursor.com 307-redirect in a loop, so use a cookieless session.
        var request = URLRequest(url: url)
        request.setValue("1", forHTTPHeaderField: "RSC")
        request.setValue("/@\(handle)", forHTTPHeaderField: "Next-Url")
        request.setValue("text/x-component", forHTTPHeaderField: "Accept")
        request.setValue("CursorBar/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await publicProfileSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
              let payload = String(data: data, encoding: .utf8)
        else {
            throw CursorAPIError.invalidResponse
        }

        if payload.contains("This profile is private") || payload.contains("profile is not public") {
            throw CursorAPIError.invalidResponse
        }

        return try parseActivityCounts(from: payload)
    }

    private static let publicProfileSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    private static func parseActivityCounts(from payload: String) throws -> [ProfileActivityDay] {
        guard let countsJSON = extractJSONArray(from: payload, labeled: "activityCounts"),
              let data = countsJSON.data(using: .utf8),
              let counts = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            throw CursorAPIError.invalidResponse
        }

        let days: [ProfileActivityDay] = counts.compactMap { day in
            guard let date = day["date"] as? String else { return nil }
            let count: Int
            switch day["count"] {
            case let number as NSNumber:
                count = number.intValue
            case let int as Int:
                count = int
            default:
                return nil
            }
            return ProfileActivityDay(date: date, count: count)
        }
        guard !days.isEmpty else { throw CursorAPIError.invalidResponse }
        return days
    }

    private static func extractJSONArray(from payload: String, labeled label: String) -> String? {
        let needle = "\"\(label)\":"
        guard let needleRange = payload.range(of: needle) else { return nil }

        var start = needleRange.upperBound
        while start < payload.endIndex, payload[start].isWhitespace {
            start = payload.index(after: start)
        }
        guard start < payload.endIndex, payload[start] == "[" else { return nil }

        var depth = 0
        var inString = false
        var escaping = false
        var index = start

        while index < payload.endIndex {
            let character = payload[index]
            if inString {
                if escaping {
                    escaping = false
                } else if character == "\\" {
                    escaping = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == "[" {
                depth += 1
            } else if character == "]" {
                depth -= 1
                if depth == 0 {
                    return String(payload[start...index])
                }
            }
            index = payload.index(after: index)
        }
        return nil
    }

    private static func utcDateString(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone(identifier: "GMT")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

private struct ProfileActivityDay {
    let date: String
    let count: Int
}

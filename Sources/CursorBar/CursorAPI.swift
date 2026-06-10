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

enum CursorAPI {
    private static let usageSummaryURL = URL(string: "https://cursor.com/api/usage-summary")!

    static func fetchUsageSummary() async throws -> UsageSummary {
        var credentials = try TokenProvider.loadSessionCredentials()

        do {
            return try await requestUsageSummary(credentials: credentials)
        } catch CursorAPIError.notAuthenticated {
            credentials = try TokenProvider.loadSessionCredentials()
            return try await requestUsageSummary(credentials: credentials)
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

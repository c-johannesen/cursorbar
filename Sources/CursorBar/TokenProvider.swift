import Foundation
import SQLite3

enum TokenProviderError: Error, LocalizedError {
    case databaseNotFound
    case tokenNotFound
    case invalidToken

    var errorDescription: String? {
        switch self {
        case .databaseNotFound:
            "Cursor database not found. Is Cursor installed and logged in?"
        case .tokenNotFound:
            "No auth token found. Please log in to Cursor."
        case .invalidToken:
            "Could not parse auth token."
        }
    }
}

struct SessionCredentials: Sendable {
    let cookieValue: String
}

enum TokenProvider {
    static let databasePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")

    static func loadSessionCredentials() throws -> SessionCredentials {
        guard FileManager.default.fileExists(atPath: databasePath.path) else {
            throw TokenProviderError.databaseNotFound
        }

        var database: OpaquePointer?
        guard sqlite3_open_v2(databasePath.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw TokenProviderError.databaseNotFound
        }
        defer { sqlite3_close(database) }

        let query = "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            throw TokenProviderError.tokenNotFound
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW,
              let cString = sqlite3_column_text(statement, 0)
        else {
            throw TokenProviderError.tokenNotFound
        }

        let accessToken = String(cString: cString)
        let userID = try extractUserID(from: accessToken)
        let cookieValue = "\(userID)%3A%3A\(accessToken)"
        return SessionCredentials(cookieValue: cookieValue)
    }

    private static func extractUserID(from jwt: String) throws -> String {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else {
            throw TokenProviderError.invalidToken
        }

        var payload = String(parts[1])
        let padding = payload.count % 4
        if padding > 0 {
            payload += String(repeating: "=", count: 4 - padding)
        }
        payload = payload
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subject = json["sub"] as? String
        else {
            throw TokenProviderError.invalidToken
        }

        if let separatorIndex = subject.lastIndex(of: "|") {
            return String(subject[subject.index(after: separatorIndex)...])
        }
        return subject
    }
}

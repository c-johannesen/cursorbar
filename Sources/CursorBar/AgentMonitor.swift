import AppKit
import Foundation
import SQLite3

struct AgentNeedingInput: Identifiable {
    let id: String
    let name: String
    let reason: String
    let lastUpdatedAt: TimeInterval

    /// Opens the agent in Cursor via the IDE's deeplink handler (`selectAgentRequested`).
    /// The `bcId` query parameter accepts local composer IDs as well as cloud agent IDs.
    func openInCursor() {
        var components = URLComponents()
        components.scheme = "cursor"
        components.host = "anysphere.cursor-deeplink"
        components.path = "/background-agent"
        components.queryItems = [URLQueryItem(name: "bcId", value: id)]
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }
}

enum AgentMonitorFormatting {
    static func compactCount(_ count: Int) -> String {
        count > 9 ? "9+" : "\(count)"
    }
}

/// Monitors live Cursor agents using local data only:
/// - Local agents: union of (a) transcript files under ~/.cursor/projects/*/agent-transcripts/
///   with a recent mtime and (b) composers in state.vscdb with a recent `lastUpdatedAt`. Newer
///   Cursor builds store composer headers in their own `composerHeaders` table (one JSON blob
///   per row, in the `value` column) instead of the older single `composer.composerHeaders`
///   JSON blob in `ItemTable`; both are read, table first. Both sources are flushed by the IDE
///   on message boundaries (every 1-3 minutes while an agent works), so we use a 4-minute
///   activity window.
/// - Cloud agents: the IDE's cached cloud agent list in state.vscdb. Older builds store this
///   under the flat key `cloudAgentRepository.agents`; newer builds namespace it per signed-in
///   account as `cloudAgentRepository.agents.<accountId>`, so both are matched and summed.
/// - Needs input: recent blocking tool approvals, or a verified unbuilt plan in
///   `composer.planRegistry` linked to the composer (`hasPendingPlan`).
@MainActor
final class AgentMonitor: ObservableObject {
    @Published var localRunningCount = 0
    @Published var cloudRunningCount = 0
    @Published var agentsNeedingInput: [AgentNeedingInput] = []

    var totalRunning: Int {
        localRunningCount + cloudRunningCount
    }

    var needsInputCount: Int {
        agentsNeedingInput.count
    }

    /// Activity within this window counts as "running". The IDE flushes agent state to disk
    /// on message boundaries, typically every 1-3 minutes during active work.
    private static let activityWindow: TimeInterval = 4 * 60
    /// Blocking tool approvals are only considered when the composer was active recently.
    private static let blockingActionWindow: TimeInterval = 30 * 60
    /// Pending plans must have registry or composer activity within this window.
    private static let pendingPlanWindow: TimeInterval = 7 * 24 * 60 * 60
    private static let pollInterval: TimeInterval = 15

    private var timer: Timer?

    init() {
        refresh()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        let snapshot = Self.readDatabaseSnapshot()
        let transcriptIDs = Self.activeLocalTranscriptIDs()

        localRunningCount = transcriptIDs.union(snapshot.activeLocalComposerIDs).count
        cloudRunningCount = snapshot.cloudRunning
        agentsNeedingInput = snapshot.agentsNeedingInput
    }

    // MARK: - Local transcripts

    /// Session IDs (composer IDs) whose transcript was written to recently.
    private static func activeLocalTranscriptIDs() -> Set<String> {
        let projectsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor/projects")
        let fileManager = FileManager.default
        guard let projects = try? fileManager.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let cutoff = Date().addingTimeInterval(-activityWindow)
        var ids: Set<String> = []

        for project in projects {
            let transcriptsDir = project.appendingPathComponent("agent-transcripts")
            guard let sessions = try? fileManager.contentsOfDirectory(
                at: transcriptsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for session in sessions {
                guard let files = try? fileManager.contentsOfDirectory(
                    at: session, includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                ) else {
                    continue
                }

                let isActive = files.contains { file in
                    guard file.pathExtension == "jsonl",
                          let values = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
                          let modified = values.contentModificationDate
                    else {
                        return false
                    }
                    return modified > cutoff
                }
                if isActive {
                    ids.insert(session.lastPathComponent)
                }
            }
        }

        return ids
    }

    // MARK: - state.vscdb (composers + cloud agents)

    private struct DatabaseSnapshot {
        var activeLocalComposerIDs: Set<String> = []
        var cloudRunning = 0
        var agentsNeedingInput: [AgentNeedingInput] = []
    }

    private static func readDatabaseSnapshot() -> DatabaseSnapshot {
        var snapshot = DatabaseSnapshot()

        var database: OpaquePointer?
        guard sqlite3_open_v2(
            TokenProvider.databasePath.path, &database, SQLITE_OPEN_READONLY, nil
        ) == SQLITE_OK else {
            return snapshot
        }
        defer { sqlite3_close(database) }

        snapshot.cloudRunning = readCloudAgentRunningCount(database: database)

        let planRegistry = readItem(database: database, key: "composer.planRegistry")
            .flatMap { data -> [String: Any]? in
                try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            } ?? [:]

        let composers = composerHeaderDicts(database: database)
        applyComposerHeaders(composers: composers, planRegistry: planRegistry, to: &snapshot)

        snapshot.agentsNeedingInput.sort { $0.lastUpdatedAt > $1.lastUpdatedAt }

        return snapshot
    }

    private static func readItem(database: OpaquePointer?, key: String) -> Data? {
        let query = "SELECT value FROM ItemTable WHERE key = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW,
              let cString = sqlite3_column_text(statement, 0)
        else {
            return nil
        }
        return String(cString: cString).data(using: .utf8)
    }

    /// Matches both the legacy flat key and newer per-account-namespaced keys
    /// (`cloudAgentRepository.agents.<accountId>`), and sums running counts across all matches.
    private static func readCloudAgentRunningCount(database: OpaquePointer?) -> Int {
        let query = "SELECT value FROM ItemTable WHERE key = ?1 OR key LIKE ?2"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            return 0
        }
        defer { sqlite3_finalize(statement) }

        let exact = "cloudAgentRepository.agents"
        let prefix = "cloudAgentRepository.agents.%"
        sqlite3_bind_text(statement, 1, exact, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(statement, 2, prefix, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        var total = 0
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let cString = sqlite3_column_text(statement, 0),
                  let data = String(cString: cString).data(using: .utf8)
            else { continue }
            total += countRunningCloudAgents(data: data)
        }
        return total
    }

    /// Reads local composer headers, preferring the newer dedicated `composerHeaders` table
    /// (one row per composer, JSON in `value`) and falling back to the older single JSON blob
    /// under the `composer.composerHeaders` key in `ItemTable` when the table doesn't exist or
    /// is empty.
    private static func composerHeaderDicts(database: OpaquePointer?) -> [[String: Any]] {
        let fromTable = composerHeaderDictsFromTable(database: database)
        if !fromTable.isEmpty {
            return fromTable
        }

        guard let data = readItem(database: database, key: "composer.composerHeaders"),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let composers = root["allComposers"] as? [[String: Any]]
        else {
            return []
        }
        return composers
    }

    private static func composerHeaderDictsFromTable(database: OpaquePointer?) -> [[String: Any]] {
        let query = "SELECT isArchived, value FROM composerHeaders"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var composers: [[String: Any]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let isArchived = sqlite3_column_int(statement, 0) != 0
            guard let cString = sqlite3_column_text(statement, 1),
                  let data = String(cString: cString).data(using: .utf8),
                  var composer = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            // The table's own `isArchived` column is authoritative; the JSON blob may omit it.
            composer["isArchived"] = isArchived
            composers.append(composer)
        }
        return composers
    }

    private static func countRunningCloudAgents(data: Data) -> Int {
        guard let agents = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return 0
        }

        // aiserver.v1.BackgroundComposerStatus: 1 = RUNNING, 4 = CREATING
        return agents.filter { agent in
            guard let status = agent["status"] as? Int else { return false }
            let isRunning = status == 1 || status == 4
            let isKilled = agent["isKilled"] as? Bool ?? false
            let isArchived = agent["isArchived"] as? Bool ?? false
            return isRunning && !isKilled && !isArchived
        }.count
    }

    private static func applyComposerHeaders(
        composers: [[String: Any]],
        planRegistry: [String: Any],
        to snapshot: inout DatabaseSnapshot
    ) {
        let nowMs = Date().timeIntervalSince1970 * 1000
        let activityCutoff = nowMs - activityWindow * 1000
        let blockingCutoff = nowMs - blockingActionWindow * 1000
        let pendingPlanCutoff = nowMs - pendingPlanWindow * 1000

        for composer in composers {
            let isArchived = composer["isArchived"] as? Bool ?? false
            let isDraft = composer["isDraft"] as? Bool ?? false
            guard !isArchived, !isDraft else { continue }

            guard let composerID = composer["composerId"] as? String else { continue }
            let lastUpdatedAt = composer["lastUpdatedAt"] as? Double ?? 0

            if let reason = composerNeedsInputReason(
                composer: composer,
                composerID: composerID,
                planRegistry: planRegistry,
                blockingCutoff: blockingCutoff,
                pendingPlanCutoff: pendingPlanCutoff
            ) {
                snapshot.agentsNeedingInput.append(
                    AgentNeedingInput(
                        id: composerID,
                        name: composerDisplayName(from: composer),
                        reason: reason,
                        lastUpdatedAt: lastUpdatedAt / 1000
                    )
                )
            }

            if lastUpdatedAt > activityCutoff {
                // Cloud-hosted chats are counted via the cloud agent cache instead.
                let locationType = (composer["agentLocation"] as? [String: Any])?["type"] as? String
                if locationType != "cloud" {
                    snapshot.activeLocalComposerIDs.insert(composerID)
                }
            }
        }
    }

    private static func composerDisplayName(from composer: [String: Any]) -> String {
        if let raw = composer["name"] as? String {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                return name
            }
        }
        return "Untitled agent"
    }

    private static func composerNeedsInputReason(
        composer: [String: Any],
        composerID: String,
        planRegistry: [String: Any],
        blockingCutoff: Double,
        pendingPlanCutoff: Double
    ) -> String? {
        let lastUpdatedAt = composer["lastUpdatedAt"] as? Double ?? 0

        if composer["hasPendingPlan"] as? Bool ?? false,
           let planName = pendingPlanName(
               forComposerID: composerID,
               in: planRegistry,
               pendingPlanCutoff: pendingPlanCutoff,
               composerLastUpdatedAt: lastUpdatedAt
           )
        {
            return "Plan ready to build: \(planName)"
        }

        if lastUpdatedAt > blockingCutoff,
           composer["hasBlockingPendingActions"] as? Bool ?? false
        {
            return "Waiting for tool approval"
        }

        return nil
    }

    private static func pendingPlanName(
        forComposerID composerID: String,
        in planRegistry: [String: Any],
        pendingPlanCutoff: Double,
        composerLastUpdatedAt: Double
    ) -> String? {
        var newestName: String?
        var newestUpdatedAt = pendingPlanCutoff

        for (_, value) in planRegistry {
            guard let entry = value as? [String: Any],
                  planEntryIsUnbuilt(entry),
                  planEntry(entry, referencesComposerID: composerID)
            else {
                continue
            }

            let planUpdatedAt = entry["lastUpdatedAt"] as? Double ?? 0
            let relevantUpdatedAt = max(planUpdatedAt, composerLastUpdatedAt)
            guard relevantUpdatedAt > pendingPlanCutoff else { continue }

            if relevantUpdatedAt >= newestUpdatedAt {
                newestUpdatedAt = relevantUpdatedAt
                newestName = entry["name"] as? String
            }
        }

        return newestName
    }

    private static func planEntryIsUnbuilt(_ entry: [String: Any]) -> Bool {
        guard let builtBy = entry["builtBy"] as? [String: Any] else { return true }
        return builtBy.isEmpty
    }

    private static func linkedComposerIDs(from entry: [String: Any]) -> Set<String> {
        var ids: Set<String> = []
        if let createdBy = entry["createdBy"] as? String {
            ids.insert(createdBy)
        }
        if let referencedBy = entry["referencedBy"] as? [String] {
            ids.formUnion(referencedBy)
        }
        if let editedBy = entry["editedBy"] as? [String] {
            ids.formUnion(editedBy)
        }
        return ids
    }

    private static func planEntry(_ entry: [String: Any], referencesComposerID composerID: String) -> Bool {
        linkedComposerIDs(from: entry).contains(composerID)
    }
}

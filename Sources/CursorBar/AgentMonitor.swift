import Foundation
import SQLite3

/// Monitors live Cursor agents using local data only:
/// - Local agents: union of (a) transcript files under ~/.cursor/projects/*/agent-transcripts/
///   with a recent mtime and (b) composers in state.vscdb (`composer.composerHeaders`) with a
///   recent `lastUpdatedAt`. Both are flushed by the IDE on message boundaries (every 1-3
///   minutes while an agent works), so we use a 4-minute activity window.
/// - Cloud agents: the IDE's cached cloud agent list in state.vscdb
///   (`cloudAgentRepository.agents`, status 1 = RUNNING, 4 = CREATING).
/// - Needs input: `hasBlockingPendingActions` (recent tool approvals) or `hasPendingPlan`
///   (plan finished and ready to build — no time limit, matches Cursor's needs-attention state).
@MainActor
final class AgentMonitor: ObservableObject {
    @Published var localRunningCount = 0
    @Published var cloudRunningCount = 0
    @Published var needsInput = false

    var totalRunning: Int {
        localRunningCount + cloudRunningCount
    }

    /// Activity within this window counts as "running". The IDE flushes agent state to disk
    /// on message boundaries, typically every 1-3 minutes during active work.
    private static let activityWindow: TimeInterval = 4 * 60
    /// Blocking tool approvals are only considered when the composer was active recently.
    private static let blockingActionWindow: TimeInterval = 30 * 60
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
        needsInput = snapshot.needsInput
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
        var needsInput = false
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

        if let data = readItem(database: database, key: "cloudAgentRepository.agents") {
            snapshot.cloudRunning = countRunningCloudAgents(data: data)
        }
        if let data = readItem(database: database, key: "composer.composerHeaders") {
            applyComposerHeaders(data: data, to: &snapshot)
        }

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

    private static func applyComposerHeaders(data: Data, to snapshot: inout DatabaseSnapshot) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let composers = root["allComposers"] as? [[String: Any]]
        else {
            return
        }

        let nowMs = Date().timeIntervalSince1970 * 1000
        let activityCutoff = nowMs - activityWindow * 1000
        let blockingCutoff = nowMs - blockingActionWindow * 1000

        for composer in composers {
            let isArchived = composer["isArchived"] as? Bool ?? false
            let isDraft = composer["isDraft"] as? Bool ?? false
            guard !isArchived, !isDraft else { continue }

            let lastUpdatedAt = composer["lastUpdatedAt"] as? Double ?? 0

            if composerNeedsInput(composer: composer, blockingCutoff: blockingCutoff) {
                snapshot.needsInput = true
            }

            if lastUpdatedAt > activityCutoff,
               let composerID = composer["composerId"] as? String
            {
                // Cloud-hosted chats are counted via the cloud agent cache instead.
                let locationType = (composer["agentLocation"] as? [String: Any])?["type"] as? String
                if locationType != "cloud" {
                    snapshot.activeLocalComposerIDs.insert(composerID)
                }
            }
        }
    }

    /// Returns true when the composer is waiting on the user — tool approval or a finished
    /// plan ready to implement (`hasPendingPlan`, matching Cursor's needs-attention badge).
    private static func composerNeedsInput(composer: [String: Any], blockingCutoff: Double) -> Bool {
        // Plan ready for implementation — no time limit; stays until the user builds or dismisses.
        if composer["hasPendingPlan"] as? Bool ?? false {
            return true
        }

        let lastUpdatedAt = composer["lastUpdatedAt"] as? Double ?? 0
        if lastUpdatedAt > blockingCutoff,
           composer["hasBlockingPendingActions"] as? Bool ?? false
        {
            return true
        }

        return false
    }
}

import AppKit
import Foundation

enum UpdateError: Error, LocalizedError {
    case requestFailed
    case noAsset
    case badArchive
    case notInstalledAsApp
    case processFailed

    var errorDescription: String? {
        switch self {
        case .requestFailed:
            "Could not reach GitHub."
        case .noAsset:
            "No download found in the latest release."
        case .badArchive:
            "Downloaded archive did not contain CursorBar.app."
        case .notInstalledAsApp:
            "CursorBar is not running from an app bundle."
        case .processFailed:
            "Update helper command failed."
        }
    }
}

@MainActor
final class UpdateChecker: ObservableObject {
    struct Release {
        let version: String
        let zipURL: URL
    }

    @Published private(set) var availableUpdate: Release?
    @Published private(set) var isChecking = false
    @Published private(set) var isUpdating = false
    @Published private(set) var statusMessage: String?

    static let currentVersion: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"

    private static let latestReleaseURL =
        URL(string: "https://api.github.com/repos/c-johannesen/cursorbar/releases/latest")!

    init() {
        Task { await checkForUpdates(announceResult: false) }
    }

    /// - Parameter announceResult: when true (manual check), also report "up to date" and failures.
    func checkForUpdates(announceResult: Bool) async {
        guard !isChecking, !isUpdating else { return }
        isChecking = true
        if announceResult {
            statusMessage = nil
        }
        defer { isChecking = false }

        do {
            var request = URLRequest(url: Self.latestReleaseURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw UpdateError.requestFailed
            }

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let latestVersion = release.tagName.hasPrefix("v")
                ? String(release.tagName.dropFirst())
                : release.tagName

            guard let asset = release.assets.first(where: { $0.name.hasSuffix(".zip") }),
                  let zipURL = URL(string: asset.browserDownloadURL)
            else {
                throw UpdateError.noAsset
            }

            if Self.isVersion(latestVersion, newerThan: Self.currentVersion) {
                availableUpdate = Release(version: latestVersion, zipURL: zipURL)
            } else {
                availableUpdate = nil
                if announceResult {
                    statusMessage = "Up to date (v\(Self.currentVersion))"
                }
            }
        } catch {
            if announceResult {
                statusMessage = "Update check failed: \(error.localizedDescription)"
            }
        }
    }

    func installUpdate() async {
        guard let update = availableUpdate, !isUpdating else { return }
        isUpdating = true
        statusMessage = "Downloading v\(update.version)…"

        do {
            let bundleURL = Bundle.main.bundleURL
            guard bundleURL.pathExtension == "app" else {
                throw UpdateError.notInstalledAsApp
            }

            let (tempZip, _) = try await URLSession.shared.download(from: update.zipURL)
            let extractDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("cursorbar-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: extractDir) }

            try await Self.runProcess("/usr/bin/ditto", ["-x", "-k", tempZip.path, extractDir.path])

            let newApp = extractDir.appendingPathComponent("CursorBar.app")
            guard FileManager.default.fileExists(atPath: newApp.path) else {
                throw UpdateError.badArchive
            }

            statusMessage = "Installing…"
            try? await Self.runProcess("/usr/bin/xattr", ["-cr", newApp.path])
            try FileManager.default.removeItem(at: bundleURL)
            try FileManager.default.copyItem(at: newApp, to: bundleURL)

            statusMessage = "Relaunching…"
            try await Self.runProcess("/usr/bin/open", ["-n", bundleURL.path])
            NSApplication.shared.terminate(nil)
        } catch {
            isUpdating = false
            statusMessage = "Update failed: \(error.localizedDescription)"
        }
    }

    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let lhs = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(lhs.count, rhs.count) {
            let a = index < lhs.count ? lhs[index] : 0
            let b = index < rhs.count ? rhs[index] : 0
            if a != b {
                return a > b
            }
        }
        return false
    }

    private static func runProcess(_ executable: String, _ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()

        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in continuation.resume() }
        }

        guard process.terminationStatus == 0 else {
            throw UpdateError.processFailed
        }
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let assets: [Asset]

    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }
}

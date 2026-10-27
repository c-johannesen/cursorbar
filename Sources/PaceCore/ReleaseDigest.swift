import CryptoKit
import Foundation

public struct ReleaseAsset: Equatable, Sendable {
    public let name: String
    public let downloadURL: String
    public let digest: String?

    public init(name: String, downloadURL: String, digest: String?) {
        self.name = name
        self.downloadURL = downloadURL
        self.digest = digest
    }
}

public struct SelectedReleaseZip: Equatable, Sendable {
    public let downloadURL: String
    public let digest: String

    public init(downloadURL: String, digest: String) {
        self.downloadURL = downloadURL
        self.digest = digest
    }
}

public enum ReleaseAssetPicker {
    /// The CursorBar zip that carries a GitHub `sha256:` digest. An unrelated
    /// archive, or a zip with no digest, is not installable.
    public static func selectCursorBarZip(_ assets: [ReleaseAsset]) -> SelectedReleaseZip? {
        guard let asset = assets.first(where: isInstallableCursorBarZip),
              let digest = asset.digest
        else { return nil }
        return SelectedReleaseZip(downloadURL: asset.downloadURL, digest: digest)
    }

    private static func isInstallableCursorBarZip(_ asset: ReleaseAsset) -> Bool {
        let name = asset.name.lowercased()
        guard name.hasSuffix(".zip"), name.contains("cursorbar") else { return false }
        guard let digest = asset.digest?.lowercased(), digest.hasPrefix("sha256:") else { return false }
        return !digest.dropFirst("sha256:".count).isEmpty
    }
}

public enum ReleaseDigest {
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func matches(data: Data, declared digest: String) -> Bool {
        let prefix = "sha256:"
        guard digest.lowercased().hasPrefix(prefix) else { return false }
        let expected = digest.dropFirst(prefix.count).lowercased()
        guard !expected.isEmpty else { return false }
        return sha256Hex(data) == expected
    }
}

import Foundation
import Crypto
import os

/// Downloads model weight files atomically (temp → SHA-256 verify → rename).
/// No bundled manifest of specific models — all manifests are user-supplied.
public actor ModelDownloadManager {

    public struct ModelManifest: Codable, Sendable {
        public let displayName: String
        public let downloadURL: URL
        public let sha256: String
        public let sizeBytes: Int
        public let providerConfigTemplate: RemoteAPIProvider.Config?

        public init(
            displayName: String,
            downloadURL: URL,
            sha256: String,
            sizeBytes: Int,
            providerConfigTemplate: RemoteAPIProvider.Config? = nil
        ) {
            self.displayName = displayName
            self.downloadURL = downloadURL
            self.sha256 = sha256
            self.sizeBytes = sizeBytes
            self.providerConfigTemplate = providerConfigTemplate
        }
    }

    public enum DownloadError: LocalizedError {
        case sha256Mismatch(expected: String, actual: String)
        case downloadFailed(String)
        case storageFailed(String)

        public var errorDescription: String? {
            switch self {
            case .sha256Mismatch: "Downloaded file failed integrity check."
            case .downloadFailed(let msg): "Download failed: \(msg)"
            case .storageFailed(let msg): "Failed to store model: \(msg)"
            }
        }
    }

    private let storageDirectory: URL
    private let logger = Logger(subsystem: "com.vibecockpit", category: "ModelDownloadManager")

    public init(storageDirectory: URL? = nil) {
        let dir: URL
        if let storageDirectory {
            dir = storageDirectory
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            )[0]
            dir = appSupport.appendingPathComponent("VibeCockpit/Models")
        }
        self.storageDirectory = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cleanPartialDownloads(in: dir)
    }

    public func download(
        from manifest: ModelManifest,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let destination = storageDirectory.appendingPathComponent(
            manifest.downloadURL.lastPathComponent
        )
        if isDownloaded(matching: manifest) { return }

        let tempURL = storageDirectory.appendingPathComponent(
            "\(manifest.downloadURL.lastPathComponent).download"
        )

        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config)
        let (downloadedURL, response) = try await session.download(from: manifest.downloadURL)

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DownloadError.downloadFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }

        try FileManager.default.moveItem(at: downloadedURL, to: tempURL)

        let actualHash = try sha256(of: tempURL)
        guard actualHash == manifest.sha256 else {
            try? FileManager.default.removeItem(at: tempURL)
            throw DownloadError.sha256Mismatch(expected: manifest.sha256, actual: actualHash)
        }

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: tempURL, to: destination)
            let name = manifest.displayName
            logger.info("Model \(name, privacy: .public) downloaded and verified.")
        } catch {
            throw DownloadError.storageFailed(error.localizedDescription)
        }
    }

    public func isDownloaded(matching manifest: ModelManifest) -> Bool {
        let destination = storageDirectory.appendingPathComponent(
            manifest.downloadURL.lastPathComponent
        )
        guard FileManager.default.fileExists(atPath: destination.path) else { return false }
        return (try? sha256(of: destination)) == manifest.sha256
    }

    public func purge(matching manifest: ModelManifest) throws {
        let destination = storageDirectory.appendingPathComponent(
            manifest.downloadURL.lastPathComponent
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
    }

    private func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    private nonisolated func cleanPartialDownloads(in directory: URL) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        for url in contents where url.pathExtension == "download" {
            try? fm.removeItem(at: url)
        }
    }
}

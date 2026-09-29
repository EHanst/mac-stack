import Crypto
import Foundation
import os

/// Downloads a catalog model into the app's Models folder — in-process, resumable and verified,
/// with no Python, no shell and no third-party download tool.
///
/// - Lists the repository's files through the Hugging Face tree API (sizes and, for large files,
///   the SHA-256 the file must have).
/// - Fetches each file in ranged chunks into `.partial/`, so an interrupted install (network drop,
///   quit, sleep) resumes from where it stopped instead of starting over.
/// - Checks the SHA-256 (or size, for small non-LFS files) and only then moves the file into
///   place, so a model directory never contains a half-written or corrupt file.
/// - Refuses to start if the disk can't hold the download.
public actor ModelInstaller {

    public struct Progress: Sendable, Equatable {
        public let bytesDone: Int64
        public let bytesTotal: Int64
        public let file: String
        public let fileIndex: Int
        public let fileCount: Int
        public var fraction: Double { bytesTotal > 0 ? Double(bytesDone) / Double(bytesTotal) : 0 }
    }

    public enum State: Sendable, Equatable { case notInstalled, partial, installed }

    public enum InstallError: LocalizedError, Equatable {
        case listingFailed(String)
        case missingRemoteFile(String)
        case insufficientDiskSpace(needed: Int64, available: Int64)
        case http(status: Int, file: String)
        case sizeMismatch(file: String)
        case hashMismatch(file: String)
        case networkUnavailable(String)
        case alreadyInstalling

        public var errorDescription: String? {
            switch self {
            case .listingFailed(let why): "Couldn't get the model's file list from Hugging Face (\(why))."
            case .missingRemoteFile(let f): "The model repository no longer contains \(f)."
            case .insufficientDiskSpace(let need, let have):
                "Not enough free disk space: the download needs about \(Self.gb(need)) GB and only \(Self.gb(have)) GB is free."
            case .http(let status, let f): "The download server returned an error (\(status)) for \(f)."
            case .sizeMismatch(let f): "\(f) downloaded with the wrong size. Please try again."
            case .hashMismatch(let f): "\(f) failed its integrity check. Please try again."
            case .networkUnavailable(let why): "The download was interrupted (\(why)). It will resume where it stopped."
            case .alreadyInstalling: "This model is already being installed."
            }
        }

        private static func gb(_ bytes: Int64) -> String { String(format: "%.1f", Double(bytes) / 1_000_000_000) }
    }

    private struct RemoteFile { let path: String; let size: Int64; let sha256: String? }

    private let root: URL
    private let session: URLSession
    private let hub: URL
    private let chunkBytes: Int64
    private let maxRetries: Int
    private let retryDelay: Duration
    private let availableBytes: @Sendable (URL) -> Int64?
    private var inFlight: Set<String> = []
    private let logger = Logger(subsystem: "com.vibecockpit", category: "ModelInstaller")

    /// Free space kept in reserve beyond the download itself.
    static let diskMargin: Int64 = 256 << 20

    public init(
        root: URL = ModelInstaller.defaultRoot(),
        session: URLSession = ModelInstaller.makeSession(),
        hub: URL = ModelInstaller.defaultHub(),
        chunkBytes: Int64 = 64 << 20,
        maxRetries: Int = 4,
        retryDelay: Duration = .seconds(1),
        availableBytes: @escaping @Sendable (URL) -> Int64? = ModelInstaller.volumeAvailableBytes
    ) {
        self.root = root
        self.session = session
        self.hub = hub
        self.chunkBytes = max(1, chunkBytes)
        self.maxRetries = maxRetries
        self.retryDelay = retryDelay
        self.availableBytes = availableBytes
    }

    /// `https://huggingface.co`, or the mirror named by the standard `HF_ENDPOINT` variable.
    /// Plain HTTP is accepted only for a loopback host (local testing); anything else falls back.
    public static func defaultHub(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let official = URL(string: "https://huggingface.co")!
        guard let raw = environment["HF_ENDPOINT"], let url = URL(string: raw), let host = url.host else { return official }
        if url.scheme == "https" { return url }
        if url.scheme == "http", ["127.0.0.1", "localhost", "::1"].contains(host) { return url }
        return official
    }

    public static func defaultRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VibeCockpit")
    }

    public static func makeSession() -> URLSession {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 60
        c.waitsForConnectivity = true
        return URLSession(configuration: c)
    }

    public static let volumeAvailableBytes: @Sendable (URL) -> Int64? = { url in
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: State

    public func installDirectory(for entry: ModelCatalogEntry) -> URL {
        root.appendingPathComponent(entry.installSubpath)
    }

    public func state(of entry: ModelCatalogEntry) -> State {
        let dir = installDirectory(for: entry)
        let fm = FileManager.default
        if entry.requiredFiles.allSatisfy({ fm.fileExists(atPath: dir.appendingPathComponent($0).path) }) {
            return .installed
        }
        return fm.fileExists(atPath: dir.appendingPathComponent(".partial").path) ? .partial : .notInstalled
    }

    // MARK: Install

    public func install(
        _ entry: ModelCatalogEntry,
        progress: @escaping @Sendable (Progress) -> Void = { _ in }
    ) async throws {
        guard inFlight.insert(entry.id).inserted else { throw InstallError.alreadyInstalling }
        defer { inFlight.remove(entry.id) }

        let dir = installDirectory(for: entry)
        let staging = dir.appendingPathComponent(".partial")
        let fm = FileManager.default

        let files = try await listFiles(entry)
        let total = files.reduce(Int64(0)) { $0 + $1.size }

        // What's already on disk: finished files, plus however much of each partial we have.
        func existingBytes(_ f: RemoteFile) -> Int64 {
            if size(of: dir.appendingPathComponent(f.path)) == f.size { return f.size }
            let part = size(of: staging.appendingPathComponent(f.path + ".part"))
            return part <= f.size ? part : 0
        }
        let already = files.reduce(Int64(0)) { $0 + existingBytes($1) }

        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let needed = (total - already) + Self.diskMargin
        if let free = availableBytes(dir), free < needed {
            throw InstallError.insufficientDiskSpace(needed: total - already + Self.diskMargin, available: free)
        }

        var done = already
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            let final = dir.appendingPathComponent(file.path)
            if size(of: final) == file.size {
                progress(Progress(bytesDone: done, bytesTotal: total, file: file.path, fileIndex: index, fileCount: files.count))
                continue
            }
            let base = done - existingBytes(file)      // bytes done before this file started
            try await download(file, entry: entry, to: final, staging: staging) { fileBytes in
                done = base + fileBytes
                progress(Progress(bytesDone: done, bytesTotal: total, file: file.path, fileIndex: index, fileCount: files.count))
            }
            done = base + file.size
        }
        try? fm.removeItem(at: staging)
        logger.info("Installed \(entry.id, privacy: .public) (\(total) bytes)")
    }

    // MARK: Listing

    private func listFiles(_ entry: ModelCatalogEntry) async throws -> [RemoteFile] {
        var components = URLComponents(
            url: hub.appendingPathComponent("api/models/\(entry.repository)/tree/main"),
            resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "recursive", value: "true")]
        let (data, response) = try await fetch(URLRequest(url: components.url!), label: "file list")
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw InstallError.listingFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw InstallError.listingFailed("unreadable response")
        }
        var byPath: [String: RemoteFile] = [:]
        for e in entries where (e["type"] as? String) == "file" {
            guard let path = e["path"] as? String, entry.include.contains(path) else { continue }
            let lfs = e["lfs"] as? [String: Any]
            let size = (lfs?["size"] as? NSNumber)?.int64Value ?? (e["size"] as? NSNumber)?.int64Value ?? 0
            byPath[path] = RemoteFile(path: path, size: size, sha256: lfs?["oid"] as? String)
        }
        return try entry.include.map { path in
            guard let f = byPath[path] else { throw InstallError.missingRemoteFile(path) }
            return f
        }
    }

    // MARK: Download one file

    private func download(
        _ file: RemoteFile, entry: ModelCatalogEntry, to final: URL, staging: URL,
        report: (Int64) -> Void
    ) async throws {
        let fm = FileManager.default
        let part = staging.appendingPathComponent(file.path + ".part")
        try fm.createDirectory(at: part.deletingLastPathComponent(), withIntermediateDirectories: true)

        var offset = size(of: part)
        if offset > file.size { try? fm.removeItem(at: part); offset = 0 }
        if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }

        var hasher = SHA256()
        if file.sha256 != nil, offset > 0 { try Self.hash(existing: part, into: &hasher) }

        let handle = try FileHandle(forWritingTo: part)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))

        let url = hub.appendingPathComponent("\(entry.repository)/resolve/main/\(file.path)")
        while offset < file.size {
            try Task.checkCancellation()
            let end = min(offset + chunkBytes, file.size) - 1
            var request = URLRequest(url: url)
            request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
            let (data, response) = try await fetch(request, label: file.path)
            guard let http = response as? HTTPURLResponse else { throw InstallError.http(status: 0, file: file.path) }

            switch http.statusCode {
            case 206:
                guard Int64(data.count) == end - offset + 1 else { throw InstallError.sizeMismatch(file: file.path) }
            case 200:
                // The server ignored Range and sent the whole file: start this file over from it.
                guard Int64(data.count) == file.size else { throw InstallError.sizeMismatch(file: file.path) }
                try handle.truncate(atOffset: 0)
                try handle.seek(toOffset: 0)
                hasher = SHA256()
                offset = 0
            default:
                throw InstallError.http(status: http.statusCode, file: file.path)
            }
            try handle.write(contentsOf: data)
            hasher.update(data: data)
            offset += Int64(data.count)
            report(offset)
        }
        try handle.close()

        guard size(of: part) == file.size else { throw InstallError.sizeMismatch(file: file.path) }
        if let expected = file.sha256 {
            let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard actual == expected else {
                try? fm.removeItem(at: part)            // corrupt: don't resume from bad bytes
                throw InstallError.hashMismatch(file: file.path)
            }
        }
        try fm.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: final)
        try fm.moveItem(at: part, to: final)
    }

    // MARK: Networking with retry

    private func fetch(_ request: URLRequest, label: String) async throws -> (Data, URLResponse) {
        var attempt = 0
        while true {
            do {
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode >= 500 || http.statusCode == 429,
                   attempt < maxRetries {
                    attempt += 1
                    try await Task.sleep(for: retryDelay * attempt)
                    continue
                }
                return (data, response)
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch let error as URLError {
                guard attempt < maxRetries else { throw InstallError.networkUnavailable(error.localizedDescription) }
                attempt += 1
                logger.notice("retrying \(label, privacy: .public) (\(attempt)/\(self.maxRetries)): \(error.localizedDescription, privacy: .public)")
                try await Task.sleep(for: retryDelay * attempt)
            }
        }
    }

    // MARK: Helpers

    private func size(of url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Re-hash the bytes already downloaded so a resumed file still verifies end to end.
    private static func hash(existing url: URL, into hasher: inout SHA256) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let block = try handle.read(upToCount: 8 << 20), !block.isEmpty { hasher.update(data: block) }
    }
}

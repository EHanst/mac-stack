import Crypto
import Testing
import Foundation
@testable import VibeCockpitCore
@testable import StackCore
@testable import StackMCP

// MARK: - Stub Hugging Face server

private final class StubServer: @unchecked Sendable {
    struct Recorded { let path: String; let range: String? }

    private let lock = NSLock()
    let host = "stub-\(UUID().uuidString.prefix(8).lowercased()).test"
    let repo = "owner/model"
    var files: [String: Data] = [:]          // repo path -> content
    var lfsPaths: Set<String> = []           // paths served with an lfs.oid (sha256)
    var extraTreeEntries: [String] = []      // files in the tree the entry does not include
    var ignoreRange = false
    var corrupt: Set<String> = []            // serve one wrong byte
    var failFirst: [String: Int] = [:]       // path -> transient failures before succeeding
    private var log: [Recorded] = []

    var requests: [Recorded] { lock.withLock { log } }
    func fileRequests(_ path: String) -> [Recorded] { requests.filter { $0.path == path } }

    var hub: URL { URL(string: "https://\(host)")! }

    func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubURLProtocol.self]
        StubURLProtocol.servers.withLock { $0[host] = self }
        return URLSession(configuration: c)
    }

    func handle(_ request: URLRequest) -> Result<(HTTPURLResponse, Data), Error> {
        let url = request.url!
        let path = url.path
        let range = request.value(forHTTPHeaderField: "Range")
        lock.withLock { log.append(Recorded(path: path.replacingOccurrences(of: "/\(repo)/resolve/main/", with: ""), range: range)) }

        if path == "/api/models/\(repo)/tree/main" {
            var entries: [[String: Any]] = [["type": "directory", "path": "onnx", "size": 0]]
            for (p, data) in files {
                var e: [String: Any] = ["type": "file", "path": p, "size": data.count]
                if lfsPaths.contains(p) {
                    e["lfs"] = ["oid": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), "size": data.count]
                }
                entries.append(e)
            }
            for p in extraTreeEntries { entries.append(["type": "file", "path": p, "size": 10]) }
            return .success((response(url, 200), try! JSONSerialization.data(withJSONObject: entries)))
        }

        let prefix = "/\(repo)/resolve/main/"
        guard path.hasPrefix(prefix), var data = files[String(path.dropFirst(prefix.count))] else {
            return .success((response(url, 404), Data()))
        }
        let name = String(path.dropFirst(prefix.count))
        if let n = lock.withLock({ failFirst[name] }), n > 0 {
            lock.withLock { failFirst[name] = n - 1 }
            return .failure(URLError(.networkConnectionLost))
        }
        if corrupt.contains(name), !data.isEmpty { data[0] ^= 0xFF }

        guard let range, !ignoreRange, range.hasPrefix("bytes=") else {
            return .success((response(url, 200), data))
        }
        let bounds = range.dropFirst(6).split(separator: "-").compactMap { Int($0) }
        let lower = bounds[0], upper = min(bounds[1], data.count - 1)
        let slice = data.subdata(in: lower..<(upper + 1))
        return .success((response(url, 206, ["Content-Range": "bytes \(lower)-\(upper)/\(data.count)"]), slice))
    }

    private func response(_ url: URL, _ status: Int, _ headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    static let servers = LockedBox<[String: StubServer]>([:])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let host = request.url?.host, let server = Self.servers.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost)); return
        }
        switch server.handle(request) {
        case .success(let (response, data)):
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

private final class LockedBox<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ v: T) { value = v }
    func withLock<R>(_ body: (inout T) -> R) -> R { lock.withLock { body(&value) } }
}

// MARK: - Fixtures

private func bytes(_ n: Int, seed: UInt8 = 1) -> Data { Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) }) }

private func entry(include: [String]) -> ModelCatalogEntry {
    ModelCatalogEntry(
        id: "test", displayName: "Test", kind: .chat, repository: "owner/model",
        installSubpath: "Models/Test", include: include, requiredFiles: [include[0]],
        approximateBytes: 0, minimumRAMBytes: nil, licenseName: "MIT",
        licenseURL: URL(string: "https://example.com/license")!, attribution: nil)
}

private func makeInstaller(_ server: StubServer, root: URL, chunk: Int64 = 1000,
                           free: Int64? = 1 << 40) -> ModelInstaller {
    ModelInstaller(root: root, session: server.session(), hub: server.hub, chunkBytes: chunk,
                   maxRetries: 3, retryDelay: .milliseconds(1), availableBytes: { _ in free })
}

private func tempRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("installer_\(UUID().uuidString)")
}

// MARK: - Tests

@Suite("ModelInstaller")
struct ModelInstallerTests {

    @Test("installs the included files with correct contents and skips everything else")
    func installsIncludedOnly() async throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let server = StubServer()
        server.files = ["config.json": bytes(300), "model.safetensors": bytes(4500, seed: 7), "sub/vocab.txt": bytes(1200, seed: 3)]
        server.lfsPaths = ["model.safetensors"]
        server.extraTreeEntries = ["runtime/runtime.py", "README.md"]
        let e = entry(include: ["config.json", "model.safetensors", "sub/vocab.txt"])
        let installer = makeInstaller(server, root: root)

        try await installer.install(e)

        let dir = await installer.installDirectory(for: e)
        for (path, data) in server.files { #expect(try Data(contentsOf: dir.appendingPathComponent(path)) == data) }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("runtime/runtime.py").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(".partial").path))
        #expect(await installer.state(of: e) == .installed)
    }

    @Test("large files are fetched in ranged chunks")
    func chunked() async throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let server = StubServer()
        server.files = ["model.safetensors": bytes(4500)]
        server.lfsPaths = ["model.safetensors"]
        try await makeInstaller(server, root: root).install(entry(include: ["model.safetensors"]))
        let ranges = server.fileRequests("model.safetensors").compactMap(\.range)
        #expect(ranges == ["bytes=0-999", "bytes=1000-1999", "bytes=2000-2999", "bytes=3000-3999", "bytes=4000-4499"])
    }

    @Test("progress is monotonic and finishes at the total")
    func progress() async throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let server = StubServer()
        server.files = ["a.bin": bytes(2500), "b.bin": bytes(1500)]
        let seen = LockedBox<[Int64]>([])
        let last = LockedBox<ModelInstaller.Progress?>(nil)
        try await makeInstaller(server, root: root).install(entry(include: ["a.bin", "b.bin"])) { p in
            seen.withLock { $0.append(p.bytesDone) }; last.withLock { $0 = p }
        }
        let values = seen.withLock { $0 }
        #expect(values == values.sorted())
        #expect(last.withLock { $0?.bytesDone } == 4000 && last.withLock { $0?.bytesTotal } == 4000)
        #expect(last.withLock { $0?.fraction } == 1.0)
    }

    @Test("resumes from a partial file: only the missing bytes are requested, and the hash still verifies")
    func resume() async throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let server = StubServer()
        let content = bytes(4500, seed: 9)
        server.files = ["model.safetensors": content]
        server.lfsPaths = ["model.safetensors"]
        let e = entry(include: ["model.safetensors"])
        let installer = makeInstaller(server, root: root)

        let part = await installer.installDirectory(for: e).appendingPathComponent(".partial/model.safetensors.part")
        try FileManager.default.createDirectory(at: part.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.prefix(2000).write(to: part)

        try await installer.install(e)

        let ranges = server.fileRequests("model.safetensors").compactMap(\.range)
        #expect(ranges.first == "bytes=2000-2999")
        #expect(!ranges.contains { $0.hasPrefix("bytes=0-") })
        let final = await installer.installDirectory(for: e).appendingPathComponent("model.safetensors")
        #expect(try Data(contentsOf: final) == content)
    }

    @Test("a corrupt download fails the integrity check, leaves no model file, and discards the bad partial")
    func hashMismatch() async throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let server = StubServer()
        server.files = ["model.safetensors": bytes(2500)]
        server.lfsPaths = ["model.safetensors"]
        server.corrupt = ["model.safetensors"]
        let e = entry(include: ["model.safetensors"])
        let installer = makeInstaller(server, root: root)
        await #expect(throws: ModelInstaller.InstallError.hashMismatch(file: "model.safetensors")) { try await installer.install(e) }
        let dir = await installer.installDirectory(for: e)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("model.safetensors").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(".partial/model.safetensors.part").path))
        #expect(await installer.state(of: e) != .installed)
    }

    @Test("not enough disk space is reported before any file is requested")
    func diskSpace() async throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let server = StubServer()
        server.files = ["model.safetensors": bytes(2500)]
        let installer = makeInstaller(server, root: root, free: 1000)
        await #expect(throws: (any Error).self) { try await installer.install(entry(include: ["model.safetensors"])) }
        #expect(server.requests.allSatisfy { !$0.path.contains("resolve") })
        do { try await installer.install(entry(include: ["model.safetensors"])) } catch let e as ModelInstaller.InstallError {
            guard case .insufficientDiskSpace(_, let available) = e else { Issue.record("wrong error \(e)"); return }
            #expect(available == 1000)
            #expect(e.localizedDescription.contains("free disk space"))
        }
    }

    @Test("transient network failures are retried")
    func retries() async throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let server = StubServer()
        server.files = ["a.bin": bytes(1500)]
        server.failFirst = ["a.bin": 2]
        try await makeInstaller(server, root: root).install(entry(include: ["a.bin"]))
        #expect(server.fileRequests("a.bin").count >= 3)
    }

    @Test("gives up with a resumable error after too many failures")
    func givesUp() async throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let server = StubServer()
        server.files = ["a.bin": bytes(1500)]
        server.failFirst = ["a.bin": 100]
        let e = entry(include: ["a.bin"])
        let installer = makeInstaller(server, root: root)
        do { try await installer.install(e); Issue.record("expected failure") }
        catch let error as ModelInstaller.InstallError {
            guard case .networkUnavailable = error else { Issue.record("wrong error \(error)"); return }
            #expect(error.localizedDescription.contains("resume"))
        }
    }

    @Test("a server that ignores Range still installs correctly")
    func ignoresRange() async throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let server = StubServer()
        let content = bytes(3200, seed: 5)
        server.files = ["model.safetensors": content]
        server.lfsPaths = ["model.safetensors"]
        server.ignoreRange = true
        let e = entry(include: ["model.safetensors"])
        let installer = makeInstaller(server, root: root)
        try await installer.install(e)
        #expect(try Data(contentsOf: await installer.installDirectory(for: e).appendingPathComponent("model.safetensors")) == content)
    }

    @Test("files that are already installed are not downloaded again")
    func skipsInstalled() async throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let server = StubServer()
        server.files = ["a.bin": bytes(1500), "b.bin": bytes(800, seed: 2)]
        let e = entry(include: ["a.bin", "b.bin"])
        let installer = makeInstaller(server, root: root)
        try await installer.install(e)
        let before = server.requests.count
        try await installer.install(e)
        #expect(server.requests.count == before + 1)     // only the file-list request
    }

    @Test("cancelling keeps the partial file, and a later install resumes from it")
    func cancelAndResume() async throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let server = StubServer()
        let content = bytes(6000, seed: 4)
        server.files = ["model.safetensors": content]
        server.lfsPaths = ["model.safetensors"]
        let e = entry(include: ["model.safetensors"])
        let installer = makeInstaller(server, root: root)

        let task = Task {
            try await installer.install(e) { p in if p.bytesDone >= 2000 { withUnsafeCurrentTask { $0?.cancel() } } }
        }
        _ = try? await task.value
        #expect(await installer.state(of: e) == .partial)

        let before = server.fileRequests("model.safetensors").count
        try await installer.install(e)
        #expect(try Data(contentsOf: await installer.installDirectory(for: e).appendingPathComponent("model.safetensors")) == content)
        let resumedRanges = server.fileRequests("model.safetensors").dropFirst(before).compactMap(\.range)
        #expect(resumedRanges.first != "bytes=0-999")       // did not start over
    }

    @Test("a file the repository no longer has is a clear error")
    func missingRemote() async throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let server = StubServer()
        server.files = ["a.bin": bytes(100)]
        await #expect(throws: ModelInstaller.InstallError.missingRemoteFile("gone.bin")) {
            try await makeInstaller(server, root: root).install(entry(include: ["a.bin", "gone.bin"]))
        }
    }

    @Test("state distinguishes installed, partial and not installed")
    func state() async throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let e = entry(include: ["a.bin"])
        let installer = makeInstaller(StubServer(), root: root)
        #expect(await installer.state(of: e) == .notInstalled)
        let dir = await installer.installDirectory(for: e)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".partial"), withIntermediateDirectories: true)
        #expect(await installer.state(of: e) == .partial)
        try Data("x".utf8).write(to: dir.appendingPathComponent("a.bin"))
        #expect(await installer.state(of: e) == .installed)
    }
}

@Suite("ModelCatalog")
struct ModelCatalogTests {
    @Test("entries only include model files, never Python or runtime extras")
    func noPython() {
        for e in ModelCatalog.all {
            #expect(!e.include.contains { $0.hasSuffix(".py") || $0.hasPrefix("runtime/") })
            #expect(e.requiredFiles.allSatisfy { e.include.contains($0) })
        }
    }

    @Test("install locations match what discovery and LocalEmbedder already scan")
    func layout() {
        #expect(ModelCatalog.bonsai27B.installSubpath == "Models/Bonsai-27B")
        #expect(ModelCatalog.bgeSmall.installSubpath == "Models/Embedders/BAAI--bge-small-en-v1.5")
        #expect(LocalEmbedder.defaultDirectory().path.hasSuffix(ModelCatalog.bgeSmall.installSubpath))
    }

    @Test("Bonsai is offered from 16 GB and carries its licence and attribution")
    func bonsaiMetadata() {
        #expect(ModelCatalog.bonsai27B.minimumRAMBytes == 16 << 30)
        #expect(ModelCatalog.bonsai27B.licenseName.contains("Apache"))
        #expect(ModelCatalog.bonsai27B.attribution?.contains("Prism ML") == true)
    }
}

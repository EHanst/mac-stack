import Foundation

public enum GitDiffError: LocalizedError, Equatable {
    case notARepository, gitUnavailable, failed(String)

    public var errorDescription: String? {
        switch self {
        case .notARepository: "This project folder is not a git repository."
        case .gitUnavailable: "git is not available on this Mac."
        case .failed(let why): "git could not read the changes: \(why)"
        }
    }
}

/// Reads uncommitted changes (tracked files, against HEAD) by running the system `git`.
/// New untracked files are not included: they have no diff until they are added.
public enum GitDiffReader {
    public static let cutMarker = "… (diff cut to fit)"

    public static func workingDiff(in root: URL, maxBytes: Int = 200_000) async throws -> String {
        let result = try await Task.detached { try run(root: root) }.value
        if result.status == 0 { return cut(result.output, maxBytes: maxBytes) }
        if result.error.localizedCaseInsensitiveContains("not a git repository") { throw GitDiffError.notARepository }
        throw GitDiffError.failed(result.error.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private struct Output { var status: Int32; var output: String; var error: String }

    private static func run(root: URL) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path, "diff", "HEAD", "--no-color"]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out; process.standardError = err
        do { try process.run() } catch { throw GitDiffError.gitUnavailable }
        // Drain both pipes before waiting, or a large diff fills the pipe and git blocks forever.
        var errData = Data()
        let errQueue = DispatchQueue(label: "git.stderr")
        let done = DispatchSemaphore(value: 0)
        errQueue.async { errData = err.fileHandleForReading.readDataToEndOfFile(); done.signal() }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        done.wait()
        process.waitUntilExit()
        return Output(status: process.terminationStatus,
                      output: String(decoding: outData, as: UTF8.self), error: String(decoding: errData, as: UTF8.self))
    }

    private static func cut(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        var kept = String(decoding: Array(text.utf8.prefix(maxBytes)), as: UTF8.self)
        if let newline = kept.lastIndex(of: "\n") { kept = String(kept[..<newline]) }
        return kept + "\n" + cutMarker
    }
}

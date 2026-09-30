import Foundation

public enum GitDiffError: LocalizedError, Equatable {
    case notARepository, noCommits, gitUnavailable, timedOut, failed(String)

    public var errorDescription: String? {
        switch self {
        case .notARepository: "This project folder is not a git repository."
        case .noCommits: "This repository has no commits yet, so there is nothing to compare against."
        case .gitUnavailable: "git is not available on this Mac."
        case .timedOut: "git took too long to read the changes."
        case .failed(let why): "git could not read the changes: \(why)"
        }
    }
}

/// Reads uncommitted changes to tracked files (against HEAD) by running the system `git`.
///
/// The project may be someone else's checkout, so repo-controlled commands are switched off:
/// no external diff drivers, textconv, fsmonitor or hooks. Git *clean filters* named in a repo's
/// `.gitattributes` can still run and cannot be disabled wholesale; only add changes from projects
/// you trust. New untracked files are not included: they have no diff until they are added.
public enum GitDiffReader {
    public static let cutMarker = "… (diff cut to fit)"
    public static let timeout: TimeInterval = 30

    public static func workingDiff(in root: URL, maxBytes: Int = 200_000) async throws -> String {
        guard isInsideRepository(root) else { throw GitDiffError.notARepository }
        let result = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Output, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do { cont.resume(returning: try run(root: root, maxBytes: maxBytes)) } catch { cont.resume(throwing: error) }
            }
        }
        if result.timedOut { throw GitDiffError.timedOut }
        if result.status == 0 || result.truncated { return cut(result.output, maxBytes: maxBytes, truncated: result.truncated) }
        let err = result.error
        if err.localizedCaseInsensitiveContains("not a git repository") { throw GitDiffError.notARepository }
        if err.contains("ambiguous argument 'HEAD'") || err.contains("bad revision 'HEAD'") { throw GitDiffError.noCommits }
        if err.contains("xcode-select") || err.contains("developer tools") { throw GitDiffError.gitUnavailable }
        throw GitDiffError.failed(err.split(separator: "\n").first.map(String.init) ?? "unknown error")
    }

    /// A `.git` directory (or file, for worktrees and submodules) in the folder or any parent.
    static func isInsideRepository(_ url: URL) -> Bool {
        var path = url.standardizedFileURL.path
        while true {
            if FileManager.default.fileExists(atPath: path + "/.git") { return true }
            if path == "/" || path.isEmpty { return false }
            path = (path as NSString).deletingLastPathComponent
        }
    }

    private struct Output { var status: Int32; var output: String; var error: String; var truncated: Bool; var timedOut: Bool }

    private static func run(root: URL, maxBytes: Int) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "-C", root.path,
            "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "diff.external=",
            "diff", "HEAD", "--no-color", "--no-ext-diff", "--no-textconv",
            "--relative", "--", ".",
        ]
        var env = ProcessInfo.processInfo.environment
        env["GIT_CONFIG_NOSYSTEM"] = "1"; env["GIT_OPTIONAL_LOCKS"] = "0"; env["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out; process.standardError = err
        do { try process.run() } catch { throw GitDiffError.gitUnavailable }

        var timedOut = false
        let watchdog = DispatchWorkItem { timedOut = true; process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        // Drain stderr concurrently so neither pipe can fill and stall git; keep it small.
        var errData = Data()
        let errDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            while let chunk = try? err.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {
                if errData.count < 16_384 { errData.append(chunk) }
            }
            errDone.signal()
        }

        // Read only as much as will be kept (plus one byte to know it was cut), then stop git.
        var data = Data()
        var truncated = false
        while let chunk = try? out.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
            data.append(chunk)
            if data.count > maxBytes { truncated = true; process.terminate(); break }
        }
        errDone.wait()
        process.waitUntilExit()
        watchdog.cancel()
        return Output(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self),
                      error: String(decoding: errData, as: UTF8.self), truncated: truncated, timedOut: timedOut)
    }

    private static func cut(_ text: String, maxBytes: Int, truncated: Bool) -> String {
        guard truncated || text.utf8.count > maxBytes else { return text }
        var kept = String(decoding: Array(text.utf8.prefix(maxBytes)), as: UTF8.self)
        if let newline = kept.lastIndex(of: "\n") { kept = String(kept[..<newline]) }
        return kept + "\n" + cutMarker
    }
}

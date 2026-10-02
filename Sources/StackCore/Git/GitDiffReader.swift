import Foundation
import CLibGit2

public enum GitDiffError: LocalizedError, Equatable {
    case notARepository, noCommits, failed(String)

    public var errorDescription: String? {
        switch self {
        case .notARepository: "This project folder is not a git repository."
        case .noCommits: "This repository has no commits yet, so there is nothing to compare against."
        case .failed(let why): "The changes could not be read: \(why)"
        }
    }
}

/// Reads uncommitted changes to tracked files (against HEAD) in-process with libgit2.
///
/// libgit2 never runs a repository's configured programs (diff drivers, textconv, fsmonitor,
/// hooks, clean filters), so reading someone else's checkout cannot execute their code. Paths in
/// the patch are relative to the repository root. New untracked files are not included: they have
/// no diff until they are added.
public enum GitDiffReader {
    public static let cutMarker = "… (diff cut to fit)"

    public static func workingDiff(in root: URL, maxBytes: Int = 200_000) async throws -> String {
        try await Task.detached(priority: .userInitiated) { try read(root: root, maxBytes: maxBytes) }.value
    }

    private final class Sink {
        var data = Data()
        var truncated = false
        let maxBytes: Int
        init(maxBytes: Int) { self.maxBytes = maxBytes }
    }

    private static let _ensureLibGit2Initialized: Void = {
        _ = git_libgit2_init()
    }()

    private static func lastError() -> String {
        giterr_last().map { String(cString: $0.pointee.message) } ?? "unknown error"
    }

    private static func read(root: URL, maxBytes: Int) throws -> String {
        _ = _ensureLibGit2Initialized

        var repo: OpaquePointer?
        let opened = git_repository_open_ext(&repo, root.path, 0, nil)
        guard opened == 0, let repo else {
            if opened == Int32(GIT_ENOTFOUND.rawValue) { throw GitDiffError.notARepository }
            throw GitDiffError.failed(lastError())
        }
        defer { git_repository_free(repo) }

        if git_repository_head_unborn(repo) == 1 { throw GitDiffError.noCommits }
        var treeObject: OpaquePointer?
        guard git_revparse_single(&treeObject, repo, "HEAD^{tree}") == 0, let treeObject else {
            throw GitDiffError.failed(lastError())
        }
        defer { git_object_free(treeObject) }

        var opts = git_diff_options()
        git_diff_options_init(&opts, UInt32(GIT_DIFF_OPTIONS_VERSION))
        let scope = relativePath(of: root, inside: repo)
        let sink = Sink(maxBytes: maxBytes)

        func diffAndPrint(_ opts: inout git_diff_options) throws {
            var diff: OpaquePointer?
            guard git_diff_tree_to_workdir_with_index(&diff, repo, treeObject, &opts) == 0, let diff else {
                throw GitDiffError.failed(lastError())
            }
            defer { git_diff_free(diff) }
            let rc = git_diff_print(diff, GIT_DIFF_FORMAT_PATCH, { _, _, line, payload in
                guard let line, let payload else { return 0 }
                let sink = Unmanaged<Sink>.fromOpaque(payload).takeUnretainedValue()
                let origin = line.pointee.origin
                if origin == CChar(UInt8(ascii: "+")) || origin == CChar(UInt8(ascii: "-")) || origin == CChar(UInt8(ascii: " ")) {
                    sink.data.append(UInt8(origin))
                }
                if line.pointee.content_len > 0, let content = line.pointee.content {
                    let buffer = UnsafeRawBufferPointer(start: content, count: line.pointee.content_len)
                    sink.data.append(contentsOf: buffer)
                }
                if sink.data.count > sink.maxBytes { sink.truncated = true; return 1 }
                return 0
            }, Unmanaged.passUnretained(sink).toOpaque())
            if rc != 0, !sink.truncated { throw GitDiffError.failed(lastError()) }
        }

        if scope.isEmpty {
            try diffAndPrint(&opts)
        } else {
            // A workspace inside a larger repository sees only its own changes.
            let path = strdup(scope)
            defer { free(path) }
            var strings: [UnsafeMutablePointer<CChar>?] = [path]
            try strings.withUnsafeMutableBufferPointer { buffer in
                opts.pathspec = git_strarray(strings: buffer.baseAddress, count: 1)
                try diffAndPrint(&opts)
            }
        }
        return cut(sink.data, maxBytes: maxBytes, truncated: sink.truncated)
    }

    /// `root` relative to the repository's working directory ("" at the top).
    private static func relativePath(of root: URL, inside repo: OpaquePointer) -> String {
        guard let workdir = git_repository_workdir(repo) else { return "" }
        let base = URL(fileURLWithPath: String(cString: workdir)).resolvingSymlinksInPath().path
        let path = root.resolvingSymlinksInPath().path
        guard path.hasPrefix(base), path != base else { return "" }
        return String(path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func cut(_ data: Data, maxBytes: Int, truncated: Bool) -> String {
        guard truncated || data.count > maxBytes else {
            return String(decoding: data, as: UTF8.self)
        }
        var end = min(maxBytes, data.count)
        if let newline = data[..<end].lastIndex(of: UInt8(ascii: "\n")) {
            end = newline
        }
        var sliced = data[..<end]
        sliced.append(UInt8(ascii: "\n"))
        sliced.append(contentsOf: cutMarker.utf8)
        return String(decoding: sliced, as: UTF8.self)
    }
}

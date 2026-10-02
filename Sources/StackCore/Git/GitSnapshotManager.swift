import Foundation
import CLibGit2
import os

public struct SnapshotRef: Sendable, Identifiable, Codable {
    public let id: UUID
    public let oid: String       // git SHA hex (40 chars)
    public let message: String
    public let createdAt: Date
    public let branchName: String

    public var shortOID: String { String(oid.prefix(7)) }

    public init(id: UUID, oid: String, message: String, createdAt: Date, branchName: String) {
        self.id = id
        self.oid = oid
        self.message = message
        self.createdAt = createdAt
        self.branchName = branchName
    }
}

public struct UnifiedDiff: Sendable {
    public let hunks: [Hunk]
    public var isEmpty: Bool { hunks.isEmpty }

    public struct Hunk: Sendable {
        public let filePath: String
        public let oldStart: Int
        public let newStart: Int
        public let lines: [DiffLine]
    }

    public struct DiffLine: Sendable {
        public enum Origin: Sendable { case context, added, deleted }
        public let origin: Origin
        public let content: String
    }
}

private final class RepoBox: @unchecked Sendable {
    var repo: OpaquePointer?
    deinit {
        if let repo { git_repository_free(repo) }
        git_libgit2_shutdown()
    }
}

/// In-memory git snapshot management via libgit2.
/// All operations serialized on this actor. No shell git calls.
public actor GitSnapshotManager {

    private let repoBox = RepoBox()
    private var repo: OpaquePointer? {
        get { repoBox.repo }
        set { repoBox.repo = newValue }
    }
    private let workspaceURL: URL
    private let logger = Logger(subsystem: "com.vibecockpit", category: "GitSnapshotManager")

    private let retryDelays: [Duration] = [.milliseconds(50), .milliseconds(100), .milliseconds(200)]

    public enum GitError: LocalizedError {
        case notARepository(String)
        case operationFailed(String)
        case lockContention
        case cleanTree

        public var errorDescription: String? {
            switch self {
            case .notARepository(let path): "'\(path)' is not a git repository."
            case .operationFailed(let msg): "Git operation failed: \(msg)"
            case .lockContention: "Git index.lock held after retries."
            case .cleanTree: "Nothing to snapshot — working tree is clean."
            }
        }
    }

    public init(workspaceURL: URL) {
        self.workspaceURL = workspaceURL
        git_libgit2_init()
    }

    public func open() throws {
        if let existing = repo {
            git_repository_free(existing)
            self.repo = nil
        }
        var r: OpaquePointer?
        let rc = git_repository_open(&r, workspaceURL.path)
        guard rc == 0, let r else {
            throw GitError.notARepository(workspaceURL.path)
        }
        self.repo = r
    }

    public func createSnapshot(message: String) async throws -> SnapshotRef {
        guard let repo else { throw GitError.notARepository(workspaceURL.path) }
        return try await withRetry { [self] in
            try self.stageAndCommit(repo: repo, message: message)
        }
    }

    public func diffAgainstSnapshot(_ ref: SnapshotRef) async throws -> UnifiedDiff {
        guard let repo else { throw GitError.notARepository(workspaceURL.path) }
        return try buildDiff(repo: repo, snapshotOid: ref.oid)
    }

    // MARK: - Private

    private func stageAndCommit(repo: OpaquePointer, message: String) throws -> SnapshotRef {
        // Stage all changes
        var index: OpaquePointer?
        guard git_repository_index(&index, repo) == 0, let index else {
            throw GitError.operationFailed(lastGitError())
        }
        defer { git_index_free(index) }
        guard git_index_add_all(index, nil, 0, nil, nil) == 0 else {
            throw GitError.operationFailed(lastGitError())
        }
        let writeRc = git_index_write(index)
        guard writeRc == 0 else {
            let msg = lastGitError()
            if writeRc == -14 || msg.localizedCaseInsensitiveContains("lock") {
                throw GitError.lockContention
            }
            throw GitError.operationFailed(msg)
        }

        // Write tree
        var treeOid = git_oid()
        guard git_index_write_tree(&treeOid, index) == 0 else {
            throw GitError.operationFailed(lastGitError())
        }

        // Clean-tree guard: refuse to snapshot when nothing changed since HEAD
        var headOidForCheck = git_oid()
        if git_reference_name_to_id(&headOidForCheck, repo, "HEAD") == 0 {
            var headCommitForCheck: OpaquePointer?
            git_commit_lookup(&headCommitForCheck, repo, &headOidForCheck)
            if let hc = headCommitForCheck {
                defer { git_commit_free(hc) }
                if let headTreeOidPtr = git_commit_tree_id(hc) {
                    // git_oid_equal returns 1 when equal
                    if git_oid_equal(&treeOid, headTreeOidPtr) != 0 {
                        throw GitError.cleanTree
                    }
                }
            }
        }

        var tree: OpaquePointer?
        git_tree_lookup(&tree, repo, &treeOid)
        defer { git_tree_free(tree) }

        // Signature
        var sig: UnsafeMutablePointer<git_signature>?
        git_signature_now(&sig, "Kokoro", "snapshot@kokoro.local")
        defer { git_signature_free(sig) }

        // Parent commit (HEAD)
        var parentCommit: OpaquePointer?
        var headOid = git_oid()
        let hasHead = git_reference_name_to_id(&headOid, repo, "HEAD") == 0
        if hasHead {
            git_commit_lookup(&parentCommit, repo, &headOid)
        }
        defer { parentCommit.map { git_commit_free($0) } }

        // Create commit
        var commitOid = git_oid()
        let rc: Int32
        if let parent = parentCommit {
            var parents: [OpaquePointer?] = [parent]
            rc = parents.withUnsafeMutableBufferPointer { buf in
                git_commit_create(&commitOid, repo, nil, sig, sig,
                                  "UTF-8", message, tree, 1, buf.baseAddress)
            }
        } else {
            rc = git_commit_create(&commitOid, repo, nil, sig, sig,
                                   "UTF-8", message, tree, 0, nil)
        }
        guard rc == 0 else { throw GitError.operationFailed(lastGitError()) }

        // OID to hex string
        var oidStr = [CChar](repeating: 0, count: 41)
        git_oid_tostr(&oidStr, 41, &commitOid)
        let oidHex = String(cString: oidStr)

        // Store snapshot ref
        let branchName = "refs/vibecockpit/snapshots/\(oidHex.prefix(8))"
        git_reference_create(nil, repo, branchName, &commitOid, 0, nil)

        return SnapshotRef(id: UUID(), oid: oidHex, message: message,
                           createdAt: Date(), branchName: branchName)
    }

    private func buildDiff(repo: OpaquePointer, snapshotOid: String) throws -> UnifiedDiff {
        var oid = git_oid()
        git_oid_fromstr(&oid, snapshotOid)
        var snapshotCommit: OpaquePointer?
        git_commit_lookup(&snapshotCommit, repo, &oid)
        defer { snapshotCommit.map { git_commit_free($0) } }
        var snapshotTree: OpaquePointer?
        if let sc = snapshotCommit { git_commit_tree(&snapshotTree, sc) }
        defer { snapshotTree.map { git_tree_free($0) } }

        var headCommit: OpaquePointer?
        var headOid = git_oid()
        if git_reference_name_to_id(&headOid, repo, "HEAD") == 0 {
            git_commit_lookup(&headCommit, repo, &headOid)
        }
        defer { headCommit.map { git_commit_free($0) } }
        var headTree: OpaquePointer?
        if let hc = headCommit { git_commit_tree(&headTree, hc) }
        defer { headTree.map { git_tree_free($0) } }

        var diff: OpaquePointer?
        var opts = git_diff_options()
        git_diff_options_init(&opts, UInt32(GIT_DIFF_OPTIONS_VERSION))
        git_diff_tree_to_tree(&diff, repo, snapshotTree, headTree, &opts)
        defer { diff.map { git_diff_free($0) } }

        guard let diff else { return UnifiedDiff(hunks: []) }
        var hunks: [UnifiedDiff.Hunk] = []
        let count = git_diff_num_deltas(diff)
        for i in 0..<count {
            if let delta = git_diff_get_delta(diff, i), delta.pointee.new_file.path != nil {
                let path = String(cString: delta.pointee.new_file.path)
                hunks.append(UnifiedDiff.Hunk(filePath: path, oldStart: 0, newStart: 0, lines: []))
            }
        }
        return UnifiedDiff(hunks: hunks)
    }

    private nonisolated func lastGitError() -> String {
        guard let err = giterr_last() else { return "Unknown git error" }
        return String(cString: err.pointee.message)
    }

    private func withRetry<T: Sendable>(_ op: () throws -> T) async throws -> T {
        var lastError: Error = GitError.lockContention
        for delay in retryDelays {
            do {
                return try op()
            } catch GitError.lockContention {
                lastError = GitError.lockContention
                logger.warning("Git lock contention, retrying after \(delay.description, privacy: .public)")
                try await Task.sleep(for: delay)
            } catch {
                throw error
            }
        }
        throw lastError
    }
}

import Testing
import Foundation
@testable import StackCore

@Suite("GitDiffReader")
struct GitDiffReaderTests {
    private func git(_ args: [String], in dir: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false"] + args
        p.currentDirectoryURL = dir
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
    }

    private func repo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try git(["init", "-q"], in: dir)
        try "one\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: dir)
        try git(["commit", "-q", "-m", "init"], in: dir)
        return dir
    }

    @Test("uncommitted edits appear in the diff; a clean tree is empty")
    func diff() async throws {
        let dir = try repo()
        #expect(try await GitDiffReader.workingDiff(in: dir) == "")
        try "changed\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        #expect(try await GitDiffReader.workingDiff(in: dir).contains("+changed"))
    }

    @Test("a folder that is not a repository is reported")
    func notARepo() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        await #expect(throws: GitDiffError.notARepository) { try await GitDiffReader.workingDiff(in: dir) }
    }

    @Test("a huge diff is cut on a line boundary with a marker")
    func cut() async throws {
        let dir = try repo()
        let big = (0..<20_000).map { "line number \($0) with some padding text" }.joined(separator: "\n") + "\n"
        try big.write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let out = try await GitDiffReader.workingDiff(in: dir, maxBytes: 50_000)
        #expect(out.utf8.count < 51_000)
        #expect(out.hasSuffix("… (diff cut to fit)"))
    }

    @Test("repo-controlled config commands are not run")
    func noConfigExecution() async throws {
        let dir = try repo()
        let marker = dir.deletingLastPathComponent().appendingPathComponent("ran-\(UUID().uuidString)")
        let script = dir.deletingLastPathComponent().appendingPathComponent("hook-\(UUID().uuidString).sh")
        try "#!/bin/sh\ntouch '\(marker.path)'\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try git(["config", "core.fsmonitor", script.path], in: dir)
        try git(["config", "diff.external", script.path], in: dir)
        try "changed\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await GitDiffReader.workingDiff(in: dir)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("a workspace inside a larger repository sees only its own changes")
    func subfolderScope() async throws {
        let dir = try repo()
        let proj = dir.appendingPathComponent("proj"), other = dir.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try "p\n".write(to: proj.appendingPathComponent("p.txt"), atomically: true, encoding: .utf8)
        try "o\n".write(to: other.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: dir); try git(["commit", "-q", "-m", "more"], in: dir)
        try "p2\n".write(to: proj.appendingPathComponent("p.txt"), atomically: true, encoding: .utf8)
        try "o2\n".write(to: other.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
        let out = try await GitDiffReader.workingDiff(in: proj)
        #expect(out.contains("+p2"))
        #expect(!out.contains("o2") && !out.contains("secret.txt"))
    }

    @Test("a repository with no commits gets a one-line explanation")
    func noCommits() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try git(["init", "-q"], in: dir)
        await #expect(throws: GitDiffError.noCommits) { try await GitDiffReader.workingDiff(in: dir) }
        #expect(GitDiffError.noCommits.errorDescription?.contains("\n") == false)
    }
}

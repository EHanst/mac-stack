import Foundation
import Crypto

/// Which repository prompts the user has read and approved. An approval is for one exact text: if the
/// file changes, it has to be approved again. Approving only means "you may put this text in the chat
/// box or offer it to other apps"; a prompt file can't grant a tool, run anything or change a setting.
public struct PromptTrust: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "approvedWorkspacePrompts"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func isApproved(id: String, hash: String) -> Bool {
        (defaults.dictionary(forKey: key) as? [String: String])?[id] == hash
    }

    public func approve(id: String, hash: String) {
        var all = (defaults.dictionary(forKey: key) as? [String: String]) ?? [:]
        all[id] = hash
        defaults.set(all, forKey: key)
    }

    public func revoke(id: String) {
        var all = (defaults.dictionary(forKey: key) as? [String: String]) ?? [:]
        all[id] = nil
        defaults.set(all, forKey: key)
    }
}

/// Prompts shipped inside a project folder (`.vibe/prompts/*.md`), so a team can share them by
/// committing them. They are someone else's text until the user approves them.
public actor WorkspacePromptStore {

    public struct Entry: Sendable, Equatable, Identifiable {
        public let prompt: SavedPrompt
        public let workspace: String
        public let fileName: String
        /// SHA-256 of the file's text; what an approval is tied to.
        public let hash: String
        public let approved: Bool
        public var id: String { prompt.id }
    }

    public static let folder = ".vibe/prompts"
    static let maxFiles = 50
    static let maxBytes = 32 * 1024

    private let roots: @Sendable () async -> [(name: String, url: URL)]
    private let trust: PromptTrust

    public init(roots: @escaping @Sendable () async -> [(name: String, url: URL)], trust: PromptTrust = PromptTrust()) {
        self.roots = roots
        self.trust = trust
    }

    public func all() async -> [Entry] {
        var out: [Entry] = []
        for root in await roots() { out += Self.scan(root: root.url, workspace: root.name, trust: trust) }
        return out.sorted { ($0.workspace, $0.prompt.title) < ($1.workspace, $1.prompt.title) }
    }

    /// Only what the user has approved; this is what other apps may see.
    public func approvedPrompts() async -> [SavedPrompt] {
        await all().filter(\.approved).map(\.prompt)
    }

    public func approve(id: String) async {
        if let entry = await all().first(where: { $0.id == id }) { trust.approve(id: id, hash: entry.hash) }
    }

    // MARK: Scanning

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Plain files only: a symlink (which could point outside the project) is skipped, as are
    /// oversized files and anything past the first 50.
    static func scan(root: URL, workspace: String, trust: PromptTrust) -> [Entry] {
        let dir = root.appendingPathComponent(folder, isDirectory: true)
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { return [] }
        var out: [Entry] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension.lowercased() == "md" {
            if out.count >= maxFiles { break }
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true, values.isRegularFile == true,
                  (values.fileSize ?? 0) <= maxBytes,
                  let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            var prompt = PromptLibrary.importMarkdown(text, fallbackTitle: file.deletingPathExtension().lastPathComponent)
            let id = "ws:\(workspace):\(file.lastPathComponent)"
            let digest = hash(text)
            prompt.id = id
            prompt.scope = .workspace
            prompt.builtIn = false
            prompt.pinned = false
            prompt.tags = (prompt.tags + [workspace]).filter { !$0.isEmpty }
            out.append(Entry(prompt: prompt, workspace: workspace, fileName: file.lastPathComponent,
                             hash: digest, approved: trust.isApproved(id: id, hash: digest)))
        }
        return out
    }
}

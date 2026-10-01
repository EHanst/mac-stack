import Foundation
import Observation
#if canImport(AppKit)
import AppKit
#endif
#if SWIFT_PACKAGE
import StackCore
#endif

/// Everything the prompt tools in the chat need: the saved-prompt library, instant checks on the
/// draft, and the "Improve" round trip. Views only read this and call it.
@MainActor
@Observable
public final class PromptStudioModel {

    public enum Phase: Equatable {
        case idle
        /// Streaming a rewrite; `partial` is the text so far.
        case running(partial: String)
        /// A finished rewrite (or a refusal / questions) waiting for the user's decision.
        case review(Optimization)
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var prompts: [SavedPrompt] = []
    /// Prompts found in project folders; each needs the user's approval before use.
    public private(set) var projectPrompts: [WorkspacePromptStore.Entry] = []
    /// Model a chat message would go to right now, and how it likes to be prompted.
    public private(set) var modelID: ProviderID?
    public private(set) var profile: ModelPromptProfile = .generic
    /// What the draft looked like before the last accepted rewrite; lets the user undo it.
    public private(set) var undoDraft: String?
    /// Models the user can choose to run "Improve" (chat-capable only; utility models are left out).
    public private(set) var choices: [InferenceService.ModelListing] = []
    public var workspaceName: String?
    /// The conversation so far (system message included), for a rewrite done by a model on this Mac.
    /// Set by `AppServices`; empty means "start from the draft alone".
    public var conversationPrefix: (@MainActor () -> [Message])?

    static let pinKey = "optimizerModelPin"

    private let library: PromptLibrary
    private let projectStore: WorkspacePromptStore?
    private let optimizer: PromptOptimizer
    private let plannedModel: @Sendable () async -> ProviderID?
    private let listModels: @Sendable () async -> [InferenceService.ModelListing]
    private let clipboard: @MainActor () -> String?
    private let defaults: UserDefaults
    private let today: () -> Date
    private var task: Task<Void, Never>?

    public init(
        library: PromptLibrary, optimizer: PromptOptimizer,
        plannedModel: @escaping @Sendable () async -> ProviderID?,
        listModels: @escaping @Sendable () async -> [InferenceService.ModelListing],
        projectPrompts: WorkspacePromptStore? = nil,
        defaults: UserDefaults = .standard,
        clipboard: @escaping @MainActor () -> String? = PromptStudioModel.systemClipboard,
        today: @escaping () -> Date = Date.init
    ) {
        self.library = library
        self.projectStore = projectPrompts
        self.optimizer = optimizer
        self.plannedModel = plannedModel
        self.listModels = listModels
        self.defaults = defaults
        self.clipboard = clipboard
        self.today = today
    }

    @MainActor public static func systemClipboard() -> String? {
        #if canImport(AppKit)
        NSPasteboard.general.string(forType: .string)
        #else
        nil
        #endif
    }

    // MARK: Library

    public func reload() async {
        prompts = await library.userPrompts()
        projectPrompts = await projectStore?.all() ?? []
    }

    public func search(_ query: String) -> [SavedPrompt] {
        let terms = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else { return prompts }
        return prompts.filter { p in
            let hay = ([p.title, p.body, p.slash ?? ""] + p.tags).joined(separator: "\n").lowercased()
            return terms.allSatisfy { hay.contains($0) }
        }
    }

    /// Lets the user vouch for one project prompt (as it reads right now).
    public func approve(_ entry: WorkspacePromptStore.Entry) async {
        await projectStore?.approve(id: entry.id)
        await reload()
    }

    /// The prompt behind `/name`: yours first, then approved project prompts.
    public func prompt(slash typed: String) -> SavedPrompt? {
        guard let key = SavedPrompt.cleanSlash(typed) else { return nil }
        return prompts.first { $0.slash == key } ?? projectPrompts.first { $0.approved && $0.prompt.slash == key }?.prompt
    }

    /// Prompts whose slash name starts with `typed` (what follows a `/` in the composer).
    public func slashMatches(_ typed: String) -> [SavedPrompt] {
        let key = typed.lowercased()
        return (prompts + projectPrompts.filter(\.approved).map(\.prompt)).filter { p in p.slash.map { $0.hasPrefix(key) } ?? false }
    }

    @discardableResult
    public func save(_ prompt: SavedPrompt) async throws -> SavedPrompt {
        let saved = try await library.save(prompt)
        await reload()
        return saved
    }

    public func delete(id: String) async throws {
        try await library.delete(id: id)
        await reload()
    }

    public func togglePinned(_ prompt: SavedPrompt) async {
        var p = prompt
        p.pinned.toggle()
        _ = try? await save(p)
    }

    public func restore(id: String, versionIndex: Int) async throws {
        try await library.restore(id: id, versionIndex: versionIndex)
        await reload()
    }

    public func resetToDefault(id: String) async throws {
        try await library.resetToDefault(id: id)
        await reload()
    }

    public func markUsed(_ id: String) async {
        await library.markUsed(id: id)
        await reload()
    }

    public func importMarkdown(_ text: String, fallbackTitle: String) async throws -> SavedPrompt {
        var p = PromptLibrary.importMarkdown(text, fallbackTitle: fallbackTitle)
        if let slash = p.slash, await library.prompt(slash: slash) != nil { p.slash = nil }   // don't steal a name
        return try await save(p)
    }

    // MARK: Using a prompt

    /// Values the app can fill in on its own for the variables this text uses.
    public func autoValues(for body: String) -> [String: String] {
        let used = Set(PromptTemplate.variables(in: body))
        var values: [String: String] = [:]
        if used.contains("workspace"), let name = workspaceName { values["workspace"] = name }
        if used.contains("date") {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            values["date"] = f.string(from: today())
        }
        if used.contains("clipboard"), let text = clipboard(), !text.isEmpty { values["clipboard"] = text }
        return values
    }

    /// Variables the user still has to fill in for `prompt` (in the body that fits the current model).
    public func fieldsToAsk(for prompt: SavedPrompt) -> [String] {
        let body = prompt.body(forFamily: profile.family)
        let auto = autoValues(for: body)
        return PromptTemplate.variables(in: body).filter { auto[$0] == nil }
    }

    /// The text to put in the composer for `prompt`, with `values` (typed by the user) and the
    /// automatic values filled in.
    public func text(for prompt: SavedPrompt, values: [String: String] = [:]) -> String {
        let body = prompt.body(forFamily: profile.family)
        return PromptTemplate.render(body, values: autoValues(for: body).merging(values) { _, typed in typed })
    }

    // MARK: Instant checks

    public func lint(_ draft: String, intent: String?) -> [PromptLint.Finding] {
        PromptLint.check(draft, context: .init(maxTokens: profile.maxUsefulTokens, intent: intent, modelFamily: profile.family))
    }

    // MARK: Improve

    /// Remembered choice of which model does the rewriting (nil = the model chat would use).
    public var optimizerPin: ProviderID? {
        get { defaults.string(forKey: Self.pinKey).flatMap { $0.isEmpty ? nil : $0 } }
        set { defaults.set(newValue ?? "", forKey: Self.pinKey) }
    }

    public func refreshModel() async {
        modelID = await plannedModel()
        profile = .profile(forProviderID: modelID)
        choices = await listModels().filter {
            $0.capabilities.contains(.textGeneration) && !$0.capabilities.contains(.speculativeDraft)
        }
    }

    public var isRunning: Bool { if case .running = phase { true } else { false } }

    /// Starts a rewrite of `draft`. Nothing is sent to the chat; the result waits in `.review`.
    public func startOptimize(draft: String, mode: OptimizeMode, intent: String?, depth: OptimizeDepth? = nil, finer: Bool = false) {
        task?.cancel()
        phase = .running(partial: "")
        task = Task { [weak self] in
            guard let self else { return }
            await self.refreshModel()
            if Task.isCancelled { return }
            let pin = self.optimizerPin
            let prefix = self.conversationPrefix?() ?? []
            // The rewrite is tailored to the model that will *receive* the prompt, not the one rewriting it.
            let context = OptimizeContext(workspaceName: self.workspaceName, intent: intent, profile: self.profile, pin: pin, sharedPrefix: prefix, depth: depth, finer: finer)
            do {
                for try await event in self.optimizer.optimize(draft: draft, context: context, mode: mode) {
                    if Task.isCancelled { return }
                    switch event {
                    case .partial(let text): self.phase = .running(partial: text)
                    case .finished(let result): self.phase = .review(result)
                    }
                }
                if case .running = self.phase { self.phase = .idle }
            } catch is CancellationError {
                self.phase = .idle
            } catch {
                if Task.isCancelled { return }
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    public func cancelOptimize() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    public func dismissReview() { phase = .idle }

    /// The user accepted `text` (the rewrite, possibly edited) in place of `original`.
    public func accepted(text: String, replacing original: String) {
        undoDraft = original
        phase = .idle
    }

    /// Returns the draft from before the last accepted rewrite, once.
    public func takeUndo() -> String? {
        defer { undoDraft = nil }
        return undoDraft
    }

    public func clearUndo() { undoDraft = nil }
}

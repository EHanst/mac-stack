import Foundation

public actor FSEventDebouncer {

    public typealias Handler = @Sendable ([URL]) async -> Void

    private let delay: Duration
    private let ignoredDirectories: Set<String>
    private let handler: Handler
    private var pendingURLs: Set<URL> = []
    private var debounceTask: Task<Void, Never>?

    public init(
        delay: Duration = .milliseconds(400),
        ignoredDirectories: Set<String> = [".build", "node_modules", ".git", "dist"],
        handler: @escaping Handler
    ) {
        self.delay = delay
        self.ignoredDirectories = ignoredDirectories
        self.handler = handler
    }

    public func received(_ urls: [URL]) {
        let filtered = urls.filter { url in
            !url.pathComponents.contains { ignoredDirectories.contains($0) }
        }
        guard !filtered.isEmpty else { return }
        filtered.forEach { pendingURLs.insert($0) }
        debounceTask?.cancel()
        let capturedDelay = delay
        debounceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: capturedDelay)
                await self?.fire()
            } catch { /* cancelled — superseded by newer batch */ }
        }
    }

    public func flush() async {
        debounceTask?.cancel()
        debounceTask = nil
        await fire()
    }

    private func fire() async {
        let batch = Array(pendingURLs)
        pendingURLs.removeAll()
        guard !batch.isEmpty else { return }
        await handler(batch)
    }
}

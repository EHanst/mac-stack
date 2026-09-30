import CoreServices
import Foundation

/// Reports file changes under a folder (FSEvents), batched by `FSEventDebouncer`.
/// Hidden folders, `.build` and friends are skipped.
public final class WorkspaceWatcher: @unchecked Sendable {

    private let debouncer: FSEventDebouncer
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.vibecockpit.workspace-watcher")

    public init(root: URL, delay: Duration = .milliseconds(400),
                handler: @escaping @Sendable ([URL]) async -> Void) {
        debouncer = FSEventDebouncer(delay: delay, handler: handler)
        let box = Unmanaged.passRetained(self)
        var context = FSEventStreamContext(version: 0, info: box.toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<WorkspaceWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let urls = list.prefix(count).map { URL(fileURLWithPath: $0) }
            Task { await watcher.debouncer.received(urls.filter { !$0.pathComponents.contains { $0.hasPrefix(".") && $0 != "." && $0 != ".." } }) }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [root.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, flags) else {
            box.release()
            return
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        Unmanaged.passUnretained(self).release()   // balances passRetained in init
    }

    deinit { if stream != nil { stop() } }
}

extension URL {
    /// The path as FSEvents reports it (symlinks resolved, `/var` → `/private/var`), also for
    /// files that no longer exist: the nearest existing parent is resolved and the rest appended.
    var canonicalPath: URL {
        var tail: [String] = []
        var base = self.standardizedFileURL
        while true {
            if let real = realpath(base.path, nil) {
                defer { free(real) }
                return tail.reversed().reduce(URL(fileURLWithPath: String(cString: real))) { $0.appendingPathComponent($1) }
            }
            guard base.pathComponents.count > 1 else { return self }
            tail.append(base.lastPathComponent)
            base = base.deletingLastPathComponent()
        }
    }
}

import Darwin
import Foundation
import Crypto

// KokoroSoak — End-to-end soak test for the Kokoro macOS app.
// Migrated from Scripts/soak.py to native Swift.
//
// Usage:
//   swift run KokoroSoak --minutes 5
//   swift run KokoroSoak --hours 24 --out ~/soak

struct Options: Sendable {
    var minutes: Double = 0
    var hours: Double = 0
    var interval: Double = 10
    var out: String = "."
    var maxGrowthPct: Double = 5.0

    var totalSeconds: Double {
        hours * 3600 + minutes * 60
    }
}

func parseArgs() -> Options {
    var opts = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--minutes":
            if let val = args.first, let d = Double(val) { opts.minutes = d; args.removeFirst() }
        case "--hours":
            if let val = args.first, let d = Double(val) { opts.hours = d; args.removeFirst() }
        case "--interval":
            if let val = args.first, let d = Double(val) { opts.interval = d; args.removeFirst() }
        case "--out":
            if let val = args.first { opts.out = val; args.removeFirst() }
        case "--max-growth-pct":
            if let val = args.first, let d = Double(val) { opts.maxGrowthPct = d; args.removeFirst() }
        case "-h", "--help":
            print("""
            Usage: KokoroSoak [options]
              --minutes <N>         Duration in minutes
              --hours <N>           Duration in hours
              --interval <N>        Seconds between samples (default: 10)
              --out <DIR>           Output directory for soak.csv and soak.json (default: .)
              --max-growth-pct <N>  Maximum permitted RSS growth percentage (default: 5.0)
            """)
            exit(0)
        default:
            fputs("Unknown argument: \(arg)\n", stderr)
            exit(1)
        }
    }
    return opts
}

// MARK: - Telemetry via Darwin Kernel APIs

func getRSSKB(pid: pid_t) -> Int {
    var procInfo = proc_taskinfo()
    let size = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &procInfo, Int32(MemoryLayout<proc_taskinfo>.size))
    if size == MemoryLayout<proc_taskinfo>.size {
        return Int(procInfo.pti_resident_size / 1024)
    }
    return 0
}

func getFDCount(pid: pid_t) -> Int {
    let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    if size > 0 {
        return Int(size) / MemoryLayout<proc_fdinfo>.size
    }
    return 0
}

// MARK: - Stub Cloud HTTP Server

final class StubServer: @unchecked Sendable {
    private let port: UInt16
    private var serverSocket: Int32 = -1
    private var isRunning = true
    private var thread: Thread?

    init(port: UInt16 = 18779) {
        self.port = port
        let t = Thread { [weak self] in
            self?.run()
        }
        t.name = "StubCloudServer"
        self.thread = t
        t.start()
    }

    func stop() {
        isRunning = false
        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }
    }

    private func run() {
        serverSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocket >= 0 else { return }

        var opt: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindRes = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        }
        guard bindRes == 0 else {
            fputs("Failed to bind stub server on port \(port)\n", stderr)
            return
        }

        listen(serverSocket, 64)

        while isRunning {
            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.stride)
            let clientSock = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(serverSocket, $0, &clientLen)
                }
            }
            guard clientSock >= 0 else {
                if !isRunning { break }
                continue
            }

            DispatchQueue.global(qos: .utility).async {
                self.handleClient(clientSock)
            }
        }
    }

    private func handleClient(_ sock: Int32) {
        defer { close(sock) }
        var buffer = [UInt8](repeating: 0, count: 8192)
        let bytesRead = read(sock, &buffer, buffer.count)
        guard bytesRead > 0 else { return }

        let req = String(decoding: buffer[..<bytesRead], as: UTF8.self)
        let firstLine = req.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.components(separatedBy: " ")
        let method = parts.first ?? "GET"

        if method == "GET" {
            let body = "{\"data\":[{\"id\":\"stub-model\"}]}"
            let resp = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            writeString(resp, to: sock)
        } else if method == "POST" {
            let isStream = req.contains("\"stream\":true") || req.contains("\"stream\": true")
            if isStream {
                let header = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
                writeString(header, to: sock)
                for chunk in ["Soak ", "test ", "reply."] {
                    let sse = "data: {\"choices\":[{\"delta\":{\"content\":\"\(chunk)\"}}]}\n\n"
                    writeString(sse, to: sock)
                    usleep(10_000)
                }
                let usage = "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":3}}\n\n"
                writeString(usage, to: sock)
                writeString("data: [DONE]\n\n", to: sock)
            } else {
                let body = "{\"choices\":[{\"message\":{\"content\":\"Soak test reply.\"}}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":3}}"
                let resp = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                writeString(resp, to: sock)
            }
        }
    }

    private func writeString(_ str: String, to sock: Int32) {
        str.utf8CString.withUnsafeBufferPointer { buf in
            guard let ptr = buf.baseAddress else { return }
            var written = 0
            let total = buf.count - 1
            while written < total {
                let n = write(sock, ptr + written, total - written)
                if n <= 0 { break }
                written += n
            }
        }
    }
}

// MARK: - Client Counters

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var ok = 0
    private(set) var err = 0
    private(set) var lastError = ""

    func recordGood() {
        lock.lock()
        defer { lock.unlock() }
        ok += 1
    }

    func recordBad(_ error: String) {
        lock.lock()
        defer { lock.unlock() }
        err += 1
        lastError = String(error.prefix(200))
    }
}

// MARK: - MCP Socket Client Wrapper

final class MCPSocket {
    private let process: Process
    private let stdinPipe: Pipe
    private let stdoutPipe: Pipe
    private var seq = 0

    init(binary: String, socketPath: String, clientName: String) throws {
        self.process = Process()
        self.stdinPipe = Pipe()
        self.stdoutPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--socket", socketPath]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        try process.run()

        _ = try call(method: "initialize", params: [
            "protocolVersion": "2025-06-18",
            "capabilities": [String: String](),
            "clientInfo": ["name": clientName, "version": "1"]
        ])
        let notif = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n"
        stdinPipe.fileHandleForWriting.write(Data(notif.utf8))
    }

    func call(method: String, params: [String: Any]) throws -> [String: Any] {
        seq += 1
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": seq,
            "method": method,
            "params": params
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        stdinPipe.fileHandleForWriting.write(data)
        stdinPipe.fileHandleForWriting.write(Data([0x0A]))

        var lineData = Data()
        var byte = [UInt8](repeating: 0, count: 1)
        while true {
            let n = read(stdoutPipe.fileHandleForReading.fileDescriptor, &byte, 1)
            if n <= 0 { throw NSError(domain: "MCPSocket", code: 1, userInfo: [NSLocalizedDescriptionKey: "Socket closed"]) }
            if byte[0] == 0x0A { break }
            lineData.append(byte[0])
        }

        guard let json = try JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
            throw NSError(domain: "MCPSocket", code: 2, userInfo: [NSLocalizedDescriptionKey: "Malformed JSON response"])
        }
        if let err = json["error"] {
            throw NSError(domain: "MCPSocket", code: 3, userInfo: [NSLocalizedDescriptionKey: "\(err)"])
        }
        return json["result"] as? [String: Any] ?? [:]
    }

    func close() {
        process.terminate()
    }
}

// MARK: - Main Execution

func main() {
    let opts = parseArgs()
    guard opts.totalSeconds > 0 else {
        fputs("Error: Specify duration via --minutes or --hours\n", stderr)
        exit(1)
    }

    let rootURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let appBinary = "/tmp/kokoro-build/Build/Products/Debug/Kokoro.app/Contents/MacOS/Kokoro"
    let mcpBinary = rootURL.appendingPathComponent(".build/debug/kokoro-mcp").path

    guard FileManager.default.fileExists(atPath: appBinary) else {
        fputs("Error: Missing Kokoro app binary at \(appBinary). Build it first.\n", stderr)
        exit(1)
    }
    guard FileManager.default.fileExists(atPath: mcpBinary) else {
        fputs("Error: Missing kokoro-mcp at \(mcpBinary). Build it via swift build.\n", stderr)
        exit(1)
    }

    let outDir = URL(fileURLWithPath: opts.out)
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

    // Isolated sandbox home
    let tempHome = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kokorosoak-\(UUID().uuidString)")
    let support = tempHome.appendingPathComponent("Library/Application Support/VibeCockpit")
    let prefs = tempHome.appendingPathComponent("Library/Preferences")
    let config = tempHome.appendingPathComponent(".config/vibecockpit")
    try! FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    try! FileManager.default.createDirectory(at: prefs, withIntermediateDirectories: true)
    try! FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)

    let token = "vc_" + UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let tokenHash = SHA256.hash(data: Data(token.utf8)).compactMap { String(format: "%02x", $0) }.joined()

    // providers.json
    let providers: [[String: Any]] = [[
        "id": "stubcloud",
        "baseURL": "http://127.0.0.1:18779/v1",
        "modelIdentifier": "stub-model",
        "capabilities": 9,
        "apiStyle": "openAIChat",
        "envVarKey": "KOKORO_STUBCLOUD_TOKEN"
    ]]
    let providersData = try! JSONSerialization.data(withJSONObject: providers)
    try! providersData.write(to: config.appendingPathComponent("providers.json"))

    // com.vibecockpit.app.plist
    let plist: [String: Any] = [
        "routingPolicy": "localFirst",
        "apiSharingEnabled": true,
        "apiSharingPort": 18081
    ]
    let plistData = try! PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
    try! plistData.write(to: prefs.appendingPathComponent("com.vibecockpit.app.plist"))

    // clients.json
    let formatter = ISO8601DateFormatter()
    let clientEntry: [[String: Any]] = [[
        "id": "00000000-0000-0000-0000-000000000001",
        "name": "soak",
        "scopes": ["models", "chat", "embeddings", "toolsRead"],
        "tokenHash": tokenHash,
        "tokenPrefix": String(token.prefix(11)),
        "createdAt": formatter.string(from: Date())
    ]]
    let clientsData = try! JSONSerialization.data(withJSONObject: clientEntry)
    let clientsURL = support.appendingPathComponent("clients.json")
    try! clientsData.write(to: clientsURL)
    try! FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: clientsURL.path)

    // Start stub server
    let stub = StubServer(port: 18779)
    defer { stub.stop() }

    // Launch Kokoro app process
    let appProcess = Process()
    appProcess.executableURL = URL(fileURLWithPath: appBinary)
    appProcess.arguments = [
        "-routingPolicy", "localFirst",
        "-apiSharingEnabled", "YES",
        "-apiSharingPort", "18081"
    ]
    var env = ProcessInfo.processInfo.environment
    env["CFFIXED_USER_HOME"] = tempHome.path
    env["KOKORO_STUBCLOUD_TOKEN"] = "throwaway"
    appProcess.environment = env

    let appLogURL = outDir.appendingPathComponent("app.log")
    FileManager.default.createFile(atPath: appLogURL.path, contents: nil)
    let logHandle = try! FileHandle(forWritingTo: appLogURL)
    appProcess.standardOutput = logHandle
    appProcess.standardError = logHandle

    try! appProcess.run()
    let pid = appProcess.processIdentifier

    let socketPath = tempHome.appendingPathComponent(".vibecockpit/mcp.sock").path
    var socketReady = false
    for _ in 0..<60 {
        if FileManager.default.fileExists(atPath: socketPath) {
            socketReady = true
            break
        }
        Thread.sleep(forTimeInterval: 1.0)
    }

    guard socketReady else {
        appProcess.terminate()
        fputs("Error: Kokoro app never opened its socket at \(socketPath)\n", stderr)
        exit(1)
    }
    Thread.sleep(forTimeInterval: 3.0)

    let isStopping = DispatchAtomicBool()
    let chatCounter = Counter()
    let streamCounter = Counter()
    let mcpCounter = Counter()

    // 1. Chat client thread
    Thread.detachNewThread {
        guard let client = try? MCPSocket(binary: mcpBinary, socketPath: socketPath, clientName: "soak-chat") else {
            chatCounter.recordBad("Failed to connect to MCP socket")
            return
        }
        while !isStopping.get() {
            do {
                let res = try client.call(method: "tools/call", params: [
                    "name": "chat",
                    "arguments": ["prompt": "say hi", "maxTokens": 20]
                ])
                if let isError = res["isError"] as? Bool, isError {
                    chatCounter.recordBad("\(res)")
                } else {
                    chatCounter.recordGood()
                }
            } catch {
                chatCounter.recordBad(error.localizedDescription)
                if error.localizedDescription.contains("closed") { break }
            }
            Thread.sleep(forTimeInterval: 1.0)
        }
        client.close()
    }

    // 2. Stream client thread
    Thread.detachNewThread {
        let session = URLSession(configuration: .ephemeral)
        let streamURL = URL(string: "http://127.0.0.1:18081/v1/chat/completions")!
        while !isStopping.get() {
            var req = URLRequest(url: streamURL)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = [
                "model": "stub-model",
                "stream": true,
                "max_tokens": 20,
                "messages": [["role": "user", "content": "say hi"]]
            ]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)

            let sem = DispatchSemaphore(value: 0)
            let task = session.dataTask(with: req) { data, response, error in
                defer { sem.signal() }
                if let error = error {
                    streamCounter.recordBad(error.localizedDescription)
                    return
                }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let str = data.flatMap({ String(data: $0, encoding: .utf8) }),
                      str.contains("[DONE]") else {
                    streamCounter.recordBad("HTTP failure or missing [DONE]")
                    return
                }
                streamCounter.recordGood()
            }
            task.resume()
            _ = sem.wait(timeout: .now() + 30)
            Thread.sleep(forTimeInterval: 1.0)
        }
    }

    // 3. MCP tools/list client thread
    Thread.detachNewThread {
        guard let client = try? MCPSocket(binary: mcpBinary, socketPath: socketPath, clientName: "soak-mcp") else {
            mcpCounter.recordBad("Failed to connect to MCP socket")
            return
        }
        while !isStopping.get() {
            do {
                _ = try client.call(method: "tools/list", params: [:])
                let res = try client.call(method: "tools/call", params: ["name": "list_models", "arguments": [:]])
                if let isError = res["isError"] as? Bool, isError {
                    mcpCounter.recordBad("\(res)")
                } else {
                    mcpCounter.recordGood()
                }
            } catch {
                mcpCounter.recordBad(error.localizedDescription)
                if error.localizedDescription.contains("closed") { break }
            }
            Thread.sleep(forTimeInterval: 1.0)
        }
        client.close()
    }

    // Sampling loop
    var samples: [(t: Int, rss: Int, fds: Int)] = []
    let startTime = Date()
    var alive = true

    let csvURL = outDir.appendingPathComponent("soak.csv")
    let csvText = "t_s,rss_kb,fds,chat_ok,chat_err,stream_ok,stream_err,mcp_ok,mcp_err\n"
    try? csvText.write(to: csvURL, atomically: true, encoding: .utf8)

    while Date().timeIntervalSince(startTime) < opts.totalSeconds {
        if !appProcess.isRunning {
            alive = false
            break
        }
        let elapsed = Int(round(Date().timeIntervalSince(startTime)))
        let rss = getRSSKB(pid: pid)
        let fds = getFDCount(pid: pid)
        samples.append((t: elapsed, rss: rss, fds: fds))

        let line = "\(elapsed),\(rss),\(fds),\(chatCounter.ok),\(chatCounter.err),\(streamCounter.ok),\(streamCounter.err),\(mcpCounter.ok),\(mcpCounter.err)\n"
        if let handle = try? FileHandle(forWritingTo: csvURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        }

        Thread.sleep(forTimeInterval: opts.interval)
    }

    isStopping.set(true)
    Thread.sleep(forTimeInterval: 2.0)

    if appProcess.isRunning {
        appProcess.terminate()
        appProcess.waitUntilExit()
    }
    try? FileManager.default.removeItem(at: tempHome)

    // Summary calculation
    var problems: [String] = []
    if !alive { problems.append("app exited during the run") }

    let totalDuration = Int(round(Date().timeIntervalSince(startTime)))
    var result: [String: Any] = [
        "seconds": totalDuration,
        "app_alive_throughout": alive,
        "clients": [
            "chat": ["ok": chatCounter.ok, "errors": chatCounter.err, "last_error": chatCounter.lastError],
            "stream": ["ok": streamCounter.ok, "errors": streamCounter.err, "last_error": streamCounter.lastError],
            "mcp": ["ok": mcpCounter.ok, "errors": mcpCounter.err, "last_error": mcpCounter.lastError]
        ]
    ]

    if samples.count >= 8 {
        let warmup = Int(Double(samples.count) * 0.1)
        let body = Array(samples[warmup...])
        let q = max(1, body.count / 4)
        let firstSlice = body.prefix(q).map { Double($0.rss) }
        let lastSlice = body.suffix(q).map { Double($0.rss) }
        let fdFirstSlice = body.prefix(q).map { Double($0.fds) }
        let fdLastSlice = body.suffix(q).map { Double($0.fds) }

        let medianFirstRSS = median(firstSlice)
        let medianLastRSS = median(lastSlice)
        let growthPct = medianFirstRSS > 0 ? round(((medianLastRSS - medianFirstRSS) / medianFirstRSS) * 10000) / 100 : 0
        let peakRSS = samples.map { $0.rss }.max() ?? 0
        let medianFirstFD = median(fdFirstSlice)
        let medianLastFD = median(fdLastSlice)

        result["rss_first_quarter_kb"] = medianFirstRSS
        result["rss_last_quarter_kb"] = medianLastRSS
        result["rss_growth_pct"] = growthPct
        result["rss_peak_kb"] = peakRSS
        result["fds_first_quarter"] = medianFirstFD
        result["fds_last_quarter"] = medianLastFD

        if growthPct > opts.maxGrowthPct {
            problems.append("RSS grew \(growthPct)% (max: \(opts.maxGrowthPct)%)")
        }
        if medianLastFD > medianFirstFD + 10 {
            problems.append("open files kept climbing (+10)")
        }
    } else {
        problems.append("too few samples to judge growth (run longer or lower --interval)")
    }

    for (name, c) in [("chat", chatCounter), ("stream", streamCounter), ("mcp", mcpCounter)] {
        let total = c.ok + c.err
        if total == 0 || Double(c.err) / Double(total) > 0.01 {
            problems.append("client \(name): \(c.err)/\(total) failed (\(c.lastError))")
        }
    }

    result["problems"] = problems
    let passed = problems.isEmpty
    result["pass"] = passed

    let jsonURL = outDir.appendingPathComponent("soak.json")
    if let jsonData = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted]),
       let jsonString = String(data: jsonData, encoding: .utf8) {
        try? jsonData.write(to: jsonURL)
        print(jsonString)
    }

    exit(passed ? 0 : 1)
}

final class DispatchAtomicBool: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    if sorted.count % 2 == 1 {
        return sorted[sorted.count / 2]
    }
    return (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2.0
}

main()

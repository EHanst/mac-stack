import Foundation

@objc public protocol BuildRunnerXPCProtocol {
    func run(command: String, workingDirectory: String, environment: [String: String],
             reply: @escaping (Data?, Error?) -> Void)
}

final class BuildRunnerImpl: NSObject, BuildRunnerXPCProtocol {
    func run(command: String, workingDirectory: String, environment: [String: String],
             reply: @escaping (Data?, Error?) -> Void) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-c", command]
        task.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        var env = ProcessInfo.processInfo.environment
        for (k, v) in environment { env[k] = v }
        task.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe

        do {
            try task.launch()
        } catch {
            reply(nil, error)
            return
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        let result: [String: Any] = [
            "exitCode": Int(task.terminationStatus),
            "stdout": String(data: outData, encoding: .utf8) ?? "",
            "stderr": String(data: errData, encoding: .utf8) ?? "",
        ]
        let encoded = try? JSONSerialization.data(withJSONObject: result)
        reply(encoded, nil)
    }
}

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: BuildRunnerXPCProtocol.self)
        connection.exportedObject = BuildRunnerImpl()
        connection.resume()
        return true
    }
}


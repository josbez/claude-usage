import Foundation

// Talks to `codex app-server` (taak 55c): JSON-RPC, one JSON object per line
// over stdin/stdout, no "jsonrpc" field. Start, handshake, one read, quit.
// Blocking: call it off the main thread.

public enum CodexAppServerError: Error, Equatable, CustomStringConvertible {
    case launch(String)
    case timeout
    /// The process ended before answering.
    case exited(Int32)
    case rpc(code: Int, message: String)
    case badResponse

    public var description: String {
        switch self {
        case .launch(let why): return "starten mislukt: \(why)"
        case .timeout: return "geen antwoord binnen de tijd"
        case .exited(let status): return "proces stopte (status \(status))"
        case .rpc(let code, let message): return "fout \(code): \(message)"
        case .badResponse: return "onleesbaar antwoord"
        }
    }
}

/// The requests we send, in order. Only `account/rateLimits/read`: nothing
/// that changes anything (never `account/rateLimitResetCredit/consume`).
func codexRequestLines(clientVersion: String) -> [Data] {
    let initialize: JSONObject = ["method": "initialize", "id": 0, "params": [
        "clientInfo": ["name": "usage_meter", "title": "Usage Meter", "version": clientVersion]]]
    let messages: [JSONObject] = [initialize, ["method": "initialized"],
                                  ["method": "account/rateLimits/read", "id": 1]]
    return messages.map { (try? JSONSerialization.data(withJSONObject: $0)) ?? Data() }
}

/// Collects stdout lines from the process and wakes the waiter per line.
final class LineReader {
    private let condition = NSCondition()
    private var buffer = Data()
    private var lines: [Data] = []
    private var closed = false

    func feed(_ data: Data) {
        condition.lock()
        if data.isEmpty { closed = true } else {
            buffer.append(data)
            while let nl = buffer.firstIndex(of: 0x0A) {
                lines.append(buffer[buffer.startIndex..<nl])
                buffer.removeSubrange(buffer.startIndex...nl)
            }
        }
        condition.broadcast()
        condition.unlock()
    }

    /// The `result` of the response with this id. Other messages (notifications
    /// such as `account/updated`) are skipped.
    func response(id: Int, until deadline: Date) -> Result<JSONObject, CodexAppServerError>? {
        condition.lock()
        defer { condition.unlock() }
        while true {
            while !lines.isEmpty {
                let line = lines.removeFirst()
                guard let msg = (try? JSONSerialization.jsonObject(with: line)) as? JSONObject,
                      jsonInt(msg["id"]) == id else { continue }
                if let err = msg["error"] as? JSONObject {
                    return .failure(.rpc(code: jsonInt(err["code"]) ?? 0, message: err["message"] as? String ?? ""))
                }
                guard let result = msg["result"] as? JSONObject else { return .failure(.badResponse) }
                return .success(result)
            }
            if closed { return nil }
            if !condition.wait(until: deadline) { return .failure(.timeout) }
        }
    }
}

/// Runs `<binary> app-server`, reads the rate limits and always stops the
/// process: terminate, then kill after `grace` seconds.
public func readCodexRateLimits(binary: URL, clientVersion: String = "dev",
                                timeout: TimeInterval = 15, grace: TimeInterval = 3) -> Result<JSONObject, CodexAppServerError> {
    let process = Process()
    process.executableURL = binary
    process.arguments = ["app-server"]
    let stdin = Pipe(), stdout = Pipe()
    // Writing to a process that already quit must fail, not SIGPIPE-kill our app.
    _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice

    let reader = LineReader()
    stdout.fileHandleForReading.readabilityHandler = { reader.feed($0.availableData) }
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }

    do {
        try process.run()
    } catch {
        stdout.fileHandleForReading.readabilityHandler = nil
        return .failure(.launch("\(error)"))
    }
    defer {
        try? stdin.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            if exited.wait(timeout: .now() + grace) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + grace)
            }
        }
        stdout.fileHandleForReading.readabilityHandler = nil
    }

    let deadline = Date().addingTimeInterval(timeout)
    let requests = codexRequestLines(clientVersion: clientVersion)
    func send(_ data: Data) -> Bool {
        // throws (instead of a SIGPIPE crash) when the process is already gone
        (try? stdin.fileHandleForWriting.write(contentsOf: data + Data([0x0A]))) != nil
    }
    func ended() -> CodexAppServerError {
        _ = exited.wait(timeout: .now() + 1)
        return process.isRunning ? .badResponse : .exited(process.terminationStatus)
    }

    guard send(requests[0]) else { return .failure(ended()) }
    switch reader.response(id: 0, until: deadline) {
    case .failure(let e)?: return .failure(e)
    case nil: return .failure(ended())
    case .success?: break
    }
    guard send(requests[1]), send(requests[2]) else { return .failure(ended()) }
    switch reader.response(id: 1, until: deadline) {
    case let r?: return r
    case nil: return .failure(ended())
    }
}

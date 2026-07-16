import Foundation

public struct AppServerExchangeResult: Sendable {
    public let stdoutLines: [Data]
    public let stderr: String
    public let terminationStatus: Int32

    public init(stdoutLines: [Data], stderr: String = "", terminationStatus: Int32 = 0) {
        self.stdoutLines = stdoutLines
        self.stderr = stderr
        self.terminationStatus = terminationStatus
    }
}

public protocol AppServerProcessExecuting: Sendable {
    func exchange(executableURL: URL, timeout: TimeInterval) async throws -> AppServerExchangeResult
}

public protocol UsageFetching: Sendable {
    func fetchSnapshot() async throws -> UsageSnapshot
}

public enum CodexUsageError: LocalizedError, Equatable, Sendable {
    case codexNotFound
    case launchFailed(String)
    case timedOut
    case processFailed(String)
    case notLoggedIn
    case protocolChanged(String)

    public var errorDescription: String? {
        switch self {
        case .codexNotFound:
            return "找不到 Codex。请安装 ChatGPT 或 Codex CLI。"
        case .launchFailed(let message):
            return "无法启动 Codex：\(message)"
        case .timedOut:
            return "读取超时，请稍后重试。"
        case .processFailed(let message):
            return "Codex 返回错误：\(message)"
        case .notLoggedIn:
            return "Codex 尚未登录 ChatGPT 账号。"
        case .protocolChanged(let message):
            return "Codex 用量协议可能已变化：\(message)"
        }
    }
}

public struct CodexAppServerClient: UsageFetching, Sendable {
    private let executor: any AppServerProcessExecuting
    private let executableURL: URL?
    private let timeout: TimeInterval

    public init(
        executor: any AppServerProcessExecuting = SubprocessAppServerExecutor(),
        executableURL: URL? = nil,
        timeout: TimeInterval = 10
    ) {
        self.executor = executor
        self.executableURL = executableURL
        self.timeout = timeout
    }

    public func fetchSnapshot() async throws -> UsageSnapshot {
        guard let executable = executableURL ?? CodexExecutableLocator.locate() else {
            throw CodexUsageError.codexNotFound
        }

        let result = try await executor.exchange(executableURL: executable, timeout: timeout)
        guard result.terminationStatus == 0 else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.looksLikeAuthenticationError(message) { throw CodexUsageError.notLoggedIn }
            throw CodexUsageError.processFailed(message.isEmpty ? "进程退出码 \(result.terminationStatus)" : message)
        }

        var rateResponse: GetAccountRateLimitsResponse?
        var usageResponse: GetAccountTokenUsageResponse?
        var rpcError: String?

        for line in result.stdoutLines {
            guard let envelope = try? JSONDecoder().decode(RPCEnvelope.self, from: line), let id = envelope.id else {
                continue
            }
            if let error = envelope.error {
                rpcError = error.message
                continue
            }
            guard let payload = envelope.result else { continue }
            if id == 2 { rateResponse = try? JSONDecoder().decode(GetAccountRateLimitsResponse.self, from: payload) }
            if id == 3 { usageResponse = try? JSONDecoder().decode(GetAccountTokenUsageResponse.self, from: payload) }
        }

        if let rpcError {
            if Self.looksLikeAuthenticationError(rpcError) { throw CodexUsageError.notLoggedIn }
            throw CodexUsageError.processFailed(rpcError)
        }
        guard let rateResponse else { throw CodexUsageError.protocolChanged("缺少额度响应") }
        guard let usageResponse else { throw CodexUsageError.protocolChanged("缺少用量响应") }

        let allLimits = rateResponse.rateLimitsByLimitId.map { Array($0.values) } ?? [rateResponse.rateLimits]
        guard let primary = allLimits.first(where: { $0.limitId == "codex" }) ?? (rateResponse.rateLimits.limitId == "codex" ? rateResponse.rateLimits : nil),
              primary.primary != nil else {
            throw CodexUsageError.protocolChanged("缺少标准 codex 额度桶")
        }

        let otherLimits = allLimits
            .filter { $0.limitId != primary.limitId && $0.primary != nil }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }

        return UsageSnapshot(
            primaryLimit: primary,
            otherLimits: otherLimits,
            dailyUsageBuckets: usageResponse.dailyUsageBuckets ?? [],
            lifetimeTokens: usageResponse.summary.lifetimeTokens,
            fetchedAt: Date()
        )
    }

    private static func looksLikeAuthenticationError(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        return lowercased.contains("not logged") || lowercased.contains("unauthorized") || lowercased.contains("authentication")
    }
}

public struct SubprocessAppServerExecutor: AppServerProcessExecuting, Sendable {
    public init() {}

    public func exchange(executableURL: URL, timeout: TimeInterval) async throws -> AppServerExchangeResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let stdinPipe = Pipe()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.executableURL = executableURL
                process.arguments = ["app-server", "--stdio"]
                process.standardInput = stdinPipe
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                let timeoutState = TimeoutState()
                let timer = DispatchWorkItem {
                    timeoutState.markTimedOut()
                    if process.isRunning { process.interrupt() }
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: CodexUsageError.launchFailed(error.localizedDescription))
                    return
                }

                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)

                do {
                    try Self.write(Self.initializeRequest, to: stdinPipe.fileHandleForWriting)
                    var buffer = Data()
                    var lines: [Data] = []
                    var sentUsageRequests = false
                    var receivedRateLimits = false
                    var receivedUsage = false

                    while !(receivedRateLimits && receivedUsage) && !timeoutState.isTimedOut {
                        let chunk = stdoutPipe.fileHandleForReading.availableData
                        if chunk.isEmpty { break }
                        buffer.append(chunk)

                        while let newline = buffer.firstIndex(of: 0x0A) {
                            let line = Data(buffer[..<newline])
                            buffer.removeSubrange(...newline)
                            guard !line.isEmpty else { continue }
                            lines.append(line)

                            if let header = try? JSONDecoder().decode(RPCHeader.self, from: line) {
                                if header.id == 1 && !sentUsageRequests {
                                    try Self.write(Self.usageRequests, to: stdinPipe.fileHandleForWriting)
                                    sentUsageRequests = true
                                }
                                if header.id == 2 { receivedRateLimits = true }
                                if header.id == 3 { receivedUsage = true }
                            }
                        }
                    }

                    timer.cancel()
                    try? stdinPipe.fileHandleForWriting.close()
                    if process.isRunning { process.interrupt() }
                    process.waitUntilExit()
                    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderr = String(data: stderrData, encoding: .utf8) ?? ""

                    if timeoutState.isTimedOut {
                        continuation.resume(throwing: CodexUsageError.timedOut)
                    } else {
                        let status: Int32 = (receivedRateLimits && receivedUsage) ? 0 : process.terminationStatus
                        continuation.resume(returning: AppServerExchangeResult(
                            stdoutLines: lines,
                            stderr: stderr,
                            terminationStatus: status
                        ))
                    }
                } catch {
                    timer.cancel()
                    if process.isRunning { process.interrupt() }
                    process.waitUntilExit()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static let initializeRequest = """
    {"id":1,"method":"initialize","params":{"clientInfo":{"name":"codex-usage-monitor","version":"1.0"},"capabilities":{"experimentalApi":true}}}
    """

    private static let usageRequests = """
    {"id":2,"method":"account/rateLimits/read","params":null}
    {"id":3,"method":"account/usage/read","params":null}
    """

    private static func write(_ string: String, to handle: FileHandle) throws {
        guard let data = (string + "\n").data(using: .utf8) else { return }
        try handle.write(contentsOf: data)
    }
}

private final class TimeoutState: @unchecked Sendable {
    private let lock = NSLock()
    private var timedOut = false

    var isTimedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    func markTimedOut() {
        lock.lock()
        timedOut = true
        lock.unlock()
    }
}

public enum CodexExecutableLocator {
    public static func locate(fileManager: FileManager = .default) -> URL? {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/.local/share/mise/installs/node/lts/bin/codex"
        ]
        return candidates
            .map(URL.init(fileURLWithPath:))
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }
}

private struct RPCHeader: Decodable {
    let id: Int?
}

private struct RPCEnvelope: Decodable {
    let id: Int?
    let result: Data?
    let error: RPCError?

    private enum CodingKeys: String, CodingKey { case id, result, error }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id)
        error = try container.decodeIfPresent(RPCError.self, forKey: .error)
        if container.contains(.result) {
            let value = try container.decode(JSONValue.self, forKey: .result)
            result = try JSONEncoder().encode(value)
        } else {
            result = nil
        }
    }
}

private struct RPCError: Decodable { let message: String }

private enum JSONValue: Codable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else { self = .number(try container.decode(Double.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

private struct GetAccountRateLimitsResponse: Decodable {
    let rateLimits: RateLimitSnapshot
    let rateLimitsByLimitId: [String: RateLimitSnapshot]?
}

private struct GetAccountTokenUsageResponse: Decodable {
    struct Summary: Decodable { let lifetimeTokens: Int64? }
    let summary: Summary
    let dailyUsageBuckets: [DailyUsageBucket]?
}

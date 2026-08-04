import Foundation
import Darwin

private enum CodexISO8601Parser {
    private static let defaultFormatter = ISO8601DateFormatter()
    private static let fractionalSecondsFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func date(from string: String) -> Date? {
        defaultFormatter.date(from: string) ?? fractionalSecondsFormatter.date(from: string)
    }
}

/// The rolling windows Codex reports for one limit id.
struct CodexRateLimits: Equatable {
    let primary: UsageRateLimitWindow?
    let secondary: UsageRateLimitWindow?
}

enum CodexRateLimitParser {
    static func parseResponse(_ data: Data) throws -> CodexRateLimits? {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let result = root?["result"] as? [String: Any]
        let byLimit = result?["rateLimitsByLimitId"] as? [String: Any]
        let codex = byLimit?["codex"] as? [String: Any]
        let fallback = result?["rateLimits"] as? [String: Any]
        return parseSnapshot(codex) ?? parseSnapshot(fallback)
    }

    static func parseResponseLine(_ line: String, expectedID: Int) throws -> CodexRateLimits? {
        guard let data = line.data(using: .utf8) else { return nil }
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard intValue(root?["id"]) == expectedID else { return nil }
        return try parseResponse(data)
    }

    private static func parseSnapshot(_ snapshot: [String: Any]?) -> CodexRateLimits? {
        guard let snapshot else { return nil }
        let primary = window(snapshot["primary"] as? [String: Any])
        let secondary = window(snapshot["secondary"] as? [String: Any])
        if primary != nil || secondary != nil {
            return CodexRateLimits(primary: primary, secondary: secondary)
        }
        // Plans without rolling windows (e.g. business seats) report a single
        // plan-wide allowance instead; without this they'd read as "no data".
        guard let individual = individualLimit(snapshot["individualLimit"] as? [String: Any]) else { return nil }
        return CodexRateLimits(primary: individual, secondary: nil)
    }

    private static func window(_ window: [String: Any]?) -> UsageRateLimitWindow? {
        guard let used = intValue(window?["usedPercent"]) else { return nil }
        return UsageRateLimitWindow(
            usedPercent: used,
            resetsAt: timeIntervalValue(window?["resetsAt"]).map { Date(timeIntervalSince1970: $0) },
            label: intValue(window?["windowDurationMins"]).map(windowLabel)
        )
    }

    private static func individualLimit(_ limit: [String: Any]?) -> UsageRateLimitWindow? {
        guard let limit else { return nil }
        let used: Int
        if let remaining = intValue(limit["remainingPercent"]) {
            used = 100 - remaining
        } else if let cap = doubleValue(limit["limit"]), cap > 0, let spent = doubleValue(limit["used"]) {
            used = Int((spent / cap * 100).rounded())
        } else {
            return nil
        }
        return UsageRateLimitWindow(
            usedPercent: max(0, min(100, used)),
            resetsAt: timeIntervalValue(limit["resetsAt"]).map { Date(timeIntervalSince1970: $0) },
            label: "quota"
        )
    }

    /// 300 → "5h", 10080 → "7d".
    static func windowLabel(minutes: Int) -> String {
        if minutes >= 1_440, minutes % 1_440 == 0 { return "\(minutes / 1_440)d" }
        if minutes >= 60, minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) ?? Double(string).map(Int.init) }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func timeIntervalValue(_ value: Any?) -> TimeInterval? {
        if let timeInterval = value as? TimeInterval { return timeInterval }
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }
}

struct CodexAppServerRateLimitClient {
    var codexExecutable: String = "codex"

    /// A GUI app inherits PATH=/usr/bin:/bin:/usr/sbin:/sbin from
    /// LaunchServices, so `/usr/bin/env codex` never finds a Homebrew or npm
    /// install — resolve the binary ourselves before spawning it.
    static func resolveExecutable(_ name: String) -> String? {
        if name.contains("/") {
            return FileManager.default.isExecutableFile(atPath: name) ? name : nil
        }
        let home = NSHomeDirectory()
        let searchPath = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.bun/bin"]
        return searchPath
            .map { ($0 as NSString).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func readRateLimit(timeout: TimeInterval = 8) -> CodexRateLimits? {
        guard let executable = Self.resolveExecutable(codexExecutable) else {
            NSLog("[CodexAppServerRateLimitClient] codex executable not found: \(codexExecutable)")
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--listen", "stdio://"]
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let outputGroup = DispatchGroup()
        let stdoutQueue = DispatchQueue(label: "codex-rate-limit.stdout")
        let stderrQueue = DispatchQueue(label: "codex-rate-limit.stderr")
        let answered = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        var rateLimits: CodexRateLimits?
        do {
            try process.run()
            outputGroup.enter()
            stdoutQueue.async {
                // Streamed rather than read-to-EOF: app-server answers the rate
                // limit call over the network and only exits once stdin closes,
                // so waiting for EOF before parsing would deadlock the two.
                var pending = Data()
                while true {
                    let chunk = stdout.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    pending.append(chunk)
                    while let newline = pending.firstIndex(of: 0x0A) {
                        let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                        pending = pending[pending.index(after: newline)...]
                        guard let parsed = try? CodexRateLimitParser.parseResponseLine(line, expectedID: 2) else { continue }
                        resultLock.lock()
                        rateLimits = parsed
                        resultLock.unlock()
                        answered.signal()
                        outputGroup.leave()
                        return
                    }
                }
                answered.signal()
                outputGroup.leave()
            }
            outputGroup.enter()
            stderrQueue.async {
                _ = stderr.fileHandleForReading.readDataToEndOfFile()
                outputGroup.leave()
            }

            let input = [
                #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"seahelm","version":"2.0.0"},"capabilities":{}}}"#,
                #"{"method":"initialized"}"#,
                #"{"id":2,"method":"account/rateLimits/read"}"#
            ].joined(separator: "\n") + "\n"
            // write(contentsOf:) throws a Swift error on EPIPE; the legacy
            // write(_:) raises an ObjC NSFileHandleOperationException that no
            // Swift catch can intercept — it crashed the app when the codex
            // process exited before reading stdin.
            // The throw only happens because EPIPE reaches us as an error at
            // all: its default disposition is SIGPIPE, which kills the process
            // outright and no `catch` can see. Ask the kernel for EPIPE.
            _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))

            _ = answered.wait(timeout: .now() + timeout)
            // stdin stays open until here on purpose: closing it earlier makes
            // app-server shut down before the answer lands.
            try? stdin.fileHandleForWriting.close()
            terminate(process)
            _ = outputGroup.wait(timeout: .now() + 1)
            resultLock.lock()
            defer { resultLock.unlock() }
            return rateLimits
        } catch {
            NSLog("[CodexAppServerRateLimitClient] Failed to read rate limits: \(error)")
            terminate(process)
            _ = outputGroup.wait(timeout: .now() + 1)
        }
        return nil
    }

    private func terminate(_ process: Process) {
        guard process.isRunning else { return }
        let group = DispatchGroup()
        group.enter()
        process.terminationHandler = { _ in group.leave() }
        process.terminate()
        if group.wait(timeout: .now() + 0.5) == .timedOut, process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            _ = group.wait(timeout: .now() + 0.5)
        }
        process.terminationHandler = nil
    }
}

struct CodexSessionUsageAggregator {
    let rootURL: URL
    let calendar: Calendar
    var modificationGraceInterval: TimeInterval? = nil

    func todayTokens(now: Date = Date()) throws -> Int {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        let files = try sessionFiles(dayStart: start)

        var total = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n") {
                guard let data = String(line).data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["type"] as? String == "event_msg",
                      let timestamp = object["timestamp"] as? String,
                      let date = CodexISO8601Parser.date(from: timestamp),
                      date >= start && date < end,
                      let payload = object["payload"] as? [String: Any],
                      payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let lastUsage = info["last_token_usage"] as? [String: Any],
                      let totalTokens = intValue(lastUsage["total_tokens"])
                else { continue }
                total += totalTokens
            }
        }
        return total
    }

    private func sessionFiles(dayStart: Date) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            throw CocoaError(.fileReadUnknown)
        }
        return enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "jsonl" && shouldReadFile($0, dayStart: dayStart) }
    }

    private func shouldReadFile(_ file: URL, dayStart: Date) -> Bool {
        guard let modificationGraceInterval else { return true }
        guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
            return true
        }
        return modified >= dayStart.addingTimeInterval(-modificationGraceInterval)
    }

    private func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }
}

struct CodexUsageSummaryProvider {
    let rateLimitClient: CodexAppServerRateLimitClient
    let sessionUsageAggregator: CodexSessionUsageAggregator

    func snapshot(now: Date = Date()) -> UsageSnapshot {
        let rateLimits = rateLimitClient.readRateLimit()
        let todayTokens = try? sessionUsageAggregator.todayTokens(now: now)
        return UsageSnapshot(
            provider: .codex,
            rateLimit: rateLimits?.primary,
            weeklyRateLimit: rateLimits?.secondary,
            todayTokens: todayTokens,
            updatedAt: now,
            isStale: rateLimits == nil && todayTokens == nil
        )
    }
}

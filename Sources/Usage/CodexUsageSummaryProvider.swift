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

enum CodexRateLimitParser {
    static func parseResponse(_ data: Data) throws -> UsageRateLimitWindow? {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let result = root?["result"] as? [String: Any]
        let byLimit = result?["rateLimitsByLimitId"] as? [String: Any]
        let codex = byLimit?["codex"] as? [String: Any]
        let fallback = result?["rateLimits"] as? [String: Any]
        return parseSnapshot(codex) ?? parseSnapshot(fallback)
    }

    static func parseResponseLine(_ line: String, expectedID: Int) throws -> UsageRateLimitWindow? {
        guard let data = line.data(using: .utf8) else { return nil }
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard intValue(root?["id"]) == expectedID else { return nil }
        return try parseResponse(data)
    }

    private static func parseSnapshot(_ snapshot: [String: Any]?) -> UsageRateLimitWindow? {
        let primary = snapshot?["primary"] as? [String: Any]
        guard let used = intValue(primary?["usedPercent"]) else { return nil }
        let resetsAt = timeIntervalValue(primary?["resetsAt"]).map { Date(timeIntervalSince1970: $0) }
        return UsageRateLimitWindow(usedPercent: used, resetsAt: resetsAt)
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
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

    func readRateLimit(timeout: TimeInterval = 5) -> UsageRateLimitWindow? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [codexExecutable, "app-server", "--listen", "stdio://"]
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let outputGroup = DispatchGroup()
        let stdoutQueue = DispatchQueue(label: "codex-rate-limit.stdout")
        let stderrQueue = DispatchQueue(label: "codex-rate-limit.stderr")
        var stdoutData = Data()
        do {
            try process.run()
            outputGroup.enter()
            stdoutQueue.async {
                stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
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
            stdin.fileHandleForWriting.write(Data(input.utf8))
            stdin.fileHandleForWriting.closeFile()

            guard waitUntilExit(process, timeout: timeout) else {
                terminate(process)
                _ = outputGroup.wait(timeout: .now() + 1)
                return nil
            }
            _ = outputGroup.wait(timeout: .now() + 1)

            for line in String(decoding: stdoutData, as: UTF8.self).split(separator: "\n") {
                if let rateLimit = try? CodexRateLimitParser.parseResponseLine(String(line), expectedID: 2) {
                    return rateLimit
                }
            }
        } catch {
            NSLog("[CodexAppServerRateLimitClient] Failed to read rate limits: \(error)")
            terminate(process)
            _ = outputGroup.wait(timeout: .now() + 1)
        }
        return nil
    }

    private func waitUntilExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let group = DispatchGroup()
        group.enter()
        process.terminationHandler = { _ in group.leave() }
        if !process.isRunning {
            process.terminationHandler = nil
            return true
        }
        let result = group.wait(timeout: .now() + timeout)
        process.terminationHandler = nil
        return result == .success
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
        let rateLimit = rateLimitClient.readRateLimit()
        let todayTokens = try? sessionUsageAggregator.todayTokens(now: now)
        return UsageSnapshot(
            provider: .codex,
            rateLimit: rateLimit,
            todayTokens: todayTokens,
            updatedAt: now,
            isStale: rateLimit == nil && todayTokens == nil
        )
    }
}

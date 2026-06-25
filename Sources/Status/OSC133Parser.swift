import Foundation

/// Parses OSC 133 escape sequences from a terminal byte stream.
/// OSC 133 is the shell integration protocol:
///   A = PromptStart, B = PromptEnd, C = PreExec, D = PostExec
enum MarkerKind {
    case promptStart   // A — prompt is being displayed
    case promptEnd     // B — prompt ended, user can type
    case preExec       // C — command is about to execute
    case postExec      // D — command finished (may include exit code)
}

struct ParsedMarker {
    let kind: MarkerKind
    let exitCode: UInt8?
    let commandLine: String?
}

enum ShellPhase {
    case prompt     // Between A and B
    case input      // Between B and C (user typing)
    case running    // Between C and D (command executing)
    case output     // After D (command finished, before next A)
}

struct ShellPhaseInfo {
    let phase: ShellPhase
    let lastExitCode: UInt8?
}

class OSC133Parser {
    private enum State {
        case normal
        case afterEsc       // Got ESC (0x1b)
        case inOSC          // Inside OSC sequence (got ESC ])
        case inOSCAfterEsc  // Got ESC inside OSC (potential ST terminator)
    }

    private var state: State = .normal
    private var oscBuffer: [UInt8] = []

    func feed(_ bytes: Data) -> [ParsedMarker] {
        var markers: [ParsedMarker] = []

        for byte in bytes {
            switch state {
            case .normal:
                if byte == 0x1b {
                    state = .afterEsc
                }
                // Ignore all other bytes in normal mode

            case .afterEsc:
                if byte == 0x5d { // ']' — start of OSC
                    state = .inOSC
                    oscBuffer.removeAll()
                } else {
                    state = .normal
                }

            case .inOSC:
                if byte == 0x07 { // BEL — OSC terminator
                    if let marker = parseOSCPayload(oscBuffer) {
                        markers.append(marker)
                    }
                    oscBuffer.removeAll()
                    state = .normal
                } else if byte == 0x1b {
                    state = .inOSCAfterEsc
                } else {
                    oscBuffer.append(byte)
                    // Safety: cap buffer to prevent runaway
                    if oscBuffer.count > 1024 {
                        oscBuffer.removeAll()
                        state = .normal
                    }
                }

            case .inOSCAfterEsc:
                if byte == 0x5c { // '\' — ST (String Terminator)
                    if let marker = parseOSCPayload(oscBuffer) {
                        markers.append(marker)
                    }
                    oscBuffer.removeAll()
                    state = .normal
                } else {
                    // Not a valid ST, discard
                    oscBuffer.removeAll()
                    state = .normal
                }
            }
        }

        return markers
    }

    func reset() {
        state = .normal
        oscBuffer.removeAll()
    }

    /// Parse "133;X", "133;X;exitcode=N", or "133;C;cmdline=..." payload
    private func parseOSCPayload(_ buffer: [UInt8]) -> ParsedMarker? {
        guard let str = String(bytes: buffer, encoding: .utf8) else { return nil }
        guard str.hasPrefix("133;") else { return nil }

        let remainder = String(str.dropFirst(4)) // after "133;"
        guard let kindChar = remainder.first else { return nil }

        let kind: MarkerKind
        switch kindChar {
        case "A": kind = .promptStart
        case "B": kind = .promptEnd
        case "C": kind = .preExec
        case "D": kind = .postExec
        default: return nil
        }

        let afterKind = String(remainder.dropFirst()) // after the kind char
        var exitCode: UInt8? = nil
        var commandLine: String? = nil

        if afterKind.hasPrefix(";") {
            let paramStr = String(afterKind.dropFirst()) // after ";"

            // Handle key=value pairs (may have multiple separated by ";")
            for part in paramStr.split(separator: ";") {
                let p = String(part)
                if p.hasPrefix("cmdline_url=") {
                    let encoded = String(p.dropFirst(12))
                    commandLine = encoded.removingPercentEncoding ?? encoded
                } else if p.hasPrefix("cmdline=") {
                    commandLine = String(p.dropFirst(8))
                } else if p.hasPrefix("exitcode=") {
                    exitCode = UInt8(String(p.dropFirst(9)))
                } else if kind == .postExec {
                    exitCode = UInt8(p)
                }
            }
        }

        return ParsedMarker(kind: kind, exitCode: exitCode, commandLine: commandLine)
    }
}

// MARK: - ShellState

class ShellState {
    private(set) var phase: ShellPhase = .output
    private(set) var lastExitCode: UInt8? = nil
    private(set) var lastCommandLine: String? = nil

    var phaseInfo: ShellPhaseInfo {
        ShellPhaseInfo(phase: phase, lastExitCode: lastExitCode)
    }

    func addMarker(_ marker: ParsedMarker) {
        switch marker.kind {
        case .promptStart:
            phase = .prompt
        case .promptEnd:
            phase = .input
        case .preExec:
            phase = .running
            if let cmd = marker.commandLine {
                lastCommandLine = cmd
            }
        case .postExec:
            phase = .output
            if let code = marker.exitCode {
                lastExitCode = code
            }
        }
    }

    func reset() {
        phase = .output
        lastExitCode = nil
        lastCommandLine = nil
    }
}

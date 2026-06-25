import AppKit

enum BackendResolver {
    struct Resolution {
        let backend: String
        let warningMessage: String?
        let zmxAvailable: Bool
    }

    static func resolvePreferredBackend(preferred: String, zmxAvailable: Bool, tmuxAvailable: Bool) -> String {
        switch preferred {
        case "local":
            if zmxAvailable { return "zmx" }
            return tmuxAvailable ? "tmux" : "local"
        case "tmux":
            if zmxAvailable { return "zmx" }
            return tmuxAvailable ? "tmux" : "local"
        case "zmx":
            if zmxAvailable {
                return "zmx"
            }
            return tmuxAvailable ? "tmux" : "local"
        default:
            if zmxAvailable {
                return "zmx"
            }
            return tmuxAvailable ? "tmux" : "local"
        }
    }

    static func isSupportedZmxVersion(_ rawVersion: String) -> Bool {
        let trimmed = rawVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let semver = trimmed
            .components(separatedBy: CharacterSet.whitespacesAndNewlines)
            .first { token in
                token.contains(".") && token.range(of: #"^v?\d+\.\d+\.\d+"#, options: .regularExpression) != nil
            }
            ?? trimmed

        let normalized = semver.hasPrefix("v") ? String(semver.dropFirst()) : semver
        let parts = normalized
            .split(separator: ".")
            .prefix(3)
            .compactMap { Int($0.filter(\.isNumber)) }

        guard parts.count == 3 else { return false }
        let major = parts[0]
        let minor = parts[1]
        let patch = parts[2]

        if major > 0 { return true }
        if minor > 4 { return true }
        if minor < 4 { return false }
        return patch >= 2
    }

    static func resolveAsync(preferred: String, completion: @escaping (Resolution) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let zmxAvailable = ProcessRunner.commandExists("zmx")
            let tmuxAvailable = ProcessRunner.commandExists("tmux")

            var zmxVersion: String?
            if preferred == "zmx" && zmxAvailable {
                zmxVersion = ProcessRunner.output(["zmx", "version"])
            }

            var targetBackend = resolvePreferredBackend(
                preferred: preferred,
                zmxAvailable: zmxAvailable,
                tmuxAvailable: tmuxAvailable
            )

            var warningMessage: String?
            if preferred == "zmx" {
                if !zmxAvailable {
                    warningMessage = "zmx is not installed. Install with `brew install neurosnap/tap/zmx`."
                } else if let version = zmxVersion, !isSupportedZmxVersion(version) {
                    warningMessage = "zmx version is too old. Please upgrade to zmx 0.4.2+ for stability."
                }
            }

            if warningMessage != nil, targetBackend == "zmx" {
                targetBackend = tmuxAvailable ? "tmux" : "local"
            }

            let resolution = Resolution(
                backend: targetBackend,
                warningMessage: warningMessage,
                zmxAvailable: zmxAvailable
            )

            DispatchQueue.main.async {
                completion(resolution)
            }
        }
    }

    static func showWarningIfNeeded(_ resolution: Resolution, configBackend: String) {
        guard let warningMessage = resolution.warningMessage else { return }

        let alert = NSAlert()
        alert.messageText = "Backend Fallback Activated"
        alert.informativeText = "\(warningMessage)\nCurrent backend: \(resolution.backend)."
        alert.alertStyle = .warning

        if configBackend == "zmx" && !resolution.zmxAvailable {
            alert.addButton(withTitle: "Copy Install Command")
            alert.addButton(withTitle: "Open zmx Docs")
            alert.addButton(withTitle: "OK")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("brew install neurosnap/tap/zmx", forType: .string)
            } else if response == .alertSecondButtonReturn,
                      let url = URL(string: "https://zmx.sh") {
                NSWorkspace.shared.open(url)
            }
        } else {
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}

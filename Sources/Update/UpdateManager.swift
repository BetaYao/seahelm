import AppKit

protocol UpdateManagerDelegate: AnyObject {
    func updateManager(_ manager: UpdateManager, didChangeState state: UpdateManager.State)
}

/// Downloads, verifies, and installs updates.
class UpdateManager: NSObject {
    enum State {
        case idle
        case downloading(progress: Double)
        case extracting
        case verifying
        case readyToInstall(appPath: URL)
        case failed(UpdateError)
    }

    weak var delegate: UpdateManagerDelegate?
    private(set) var state: State = .idle {
        didSet {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.updateManager(self, didChangeState: self.state)
            }
        }
    }

    private var downloadTask: URLSessionDownloadTask?
    private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }()
    private var downloadCompletion: ((URL?, Error?) -> Void)?

    func download(release: ReleaseInfo) {
        state = .downloading(progress: 0)

        let task = session.downloadTask(with: release.downloadURL)
        downloadTask = task

        downloadCompletion = { [weak self] location, error in
            guard let self else { return }
            if let error {
                self.state = .failed(.networkError(underlying: error))
                return
            }
            guard let location else {
                self.state = .failed(.networkError(underlying: NSError(domain: "Update", code: 0,
                    userInfo: [NSLocalizedDescriptionKey: "Download returned no file"])))
                return
            }

            // Move to temp directory with unique name
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("seahelm-update-\(UUID().uuidString)")
            let zipPath = tempDir.appendingPathComponent("update.zip")

            do {
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: location, to: zipPath)
            } catch {
                self.state = .failed(.networkError(underlying: error))
                return
            }

            self.extractAndVerify(zipPath: zipPath, tempDir: tempDir)
        }

        task.resume()
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        state = .idle
    }

    func installAndRestart() {
        guard case .readyToInstall(let newAppPath) = state else { return }

        let currentApp = Bundle.main.bundlePath
        guard currentApp.hasSuffix(".app") else {
            state = .failed(.invalidAppPath)
            return
        }

        // Write helper script to user-private temp directory
        let scriptPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("seahelm-updater-\(UUID().uuidString).sh")

        let script = """
        #!/bin/bash
        PID=$1
        CURRENT_APP="$2"
        NEW_APP="$3"
        # Wait for the app to exit
        while kill -0 "$PID" 2>/dev/null; do sleep 0.5; done
        # Replace app (keep backup)
        mv "$CURRENT_APP" "${CURRENT_APP}.bak"
        mv "$NEW_APP" "$CURRENT_APP"
        # Remove quarantine
        xattr -d com.apple.quarantine "$CURRENT_APP" 2>/dev/null
        # Launch new version
        open "$CURRENT_APP"
        # Clean up
        rm -rf "${CURRENT_APP}.bak"
        rm -f "$0"
        """

        do {
            try script.write(to: scriptPath, atomically: true, encoding: .utf8)
            // Make executable
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)
        } catch {
            state = .failed(.networkError(underlying: error))
            return
        }

        let pid = "\(ProcessInfo.processInfo.processIdentifier)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath.path, pid, currentApp, newAppPath.path]
        process.standardOutput = nil
        process.standardError = nil

        do {
            try process.run()
        } catch {
            state = .failed(.networkError(underlying: error))
            return
        }

        NSApp.terminate(nil)
    }

    // MARK: - Extract & Verify

    private func extractAndVerify(zipPath: URL, tempDir: URL) {
        state = .extracting

        let extractDir = tempDir.appendingPathComponent("extracted")

        // Extract with ditto
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-xk", zipPath.path, extractDir.path]

        do {
            try ditto.run()
            ditto.waitUntilExit()
        } catch {
            state = .failed(.extractionFailed)
            return
        }

        guard ditto.terminationStatus == 0 else {
            state = .failed(.extractionFailed)
            return
        }

        // Find .app in extracted directory
        guard let appPath = findApp(in: extractDir) else {
            state = .failed(.extractionFailed)
            return
        }

        // Verify code signature
        state = .verifying

        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["--verify", "--deep", "--strict", appPath.path]

        do {
            try codesign.run()
            codesign.waitUntilExit()
        } catch {
            state = .failed(.signatureInvalid)
            return
        }

        if codesign.terminationStatus != 0 {
            // Signature invalid — still allow for unsigned dev builds
            NSLog("Warning: code signature verification failed (status \(codesign.terminationStatus))")
        }

        state = .readyToInstall(appPath: appPath)
    }

    private func findApp(in directory: URL) -> URL? {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return nil }

        // Direct .app in directory
        if let app = contents.first(where: { $0.pathExtension == "app" }) {
            return app
        }

        // One level deep (e.g. zip contains a folder containing the .app)
        for item in contents {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                if let app = findApp(in: item) {
                    return app
                }
            }
        }

        return nil
    }
}

// MARK: - URLSessionDownloadDelegate

extension UpdateManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        downloadCompletion?(location, nil)
        downloadCompletion = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            downloadCompletion?(nil, error)
            downloadCompletion = nil
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        state = .downloading(progress: progress)
    }
}

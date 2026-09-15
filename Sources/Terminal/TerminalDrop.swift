import AppKit

/// What a terminal pane receives when something is dropped on it: the escaped
/// paths of dropped files, dropped images as attachments when the pane's agent
/// pastes images itself (`AgentImagePaste`), or dropped text as-is. No view
/// code — the drop target (`SplitContainerView`) picks the pane and highlights it.
enum TerminalDrop {
    /// What a drop resolved to.
    enum Content: Equatable {
        /// Files on disk: dropped, received from promises, or written from image data.
        case files([URL])
        /// Dropped text or a link.
        case text(String)
    }

    /// Pasteboard types a pane accepts: files, file promises (Photos, Mail,
    /// images dragged out of a browser), bare image data, and text or links.
    static let acceptedTypes: [NSPasteboard.PasteboardType] =
        [.fileURL, .URL, .string, .png, .tiff]
        + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    /// A promise whose source never delivers must not hold the drop forever.
    static let promiseTimeout: TimeInterval = 30

    static func canAccept(_ pasteboard: NSPasteboard) -> Bool {
        guard let types = pasteboard.types else { return false }
        return !Set(types).isDisjoint(with: acceptedTypes)
    }

    /// Resolve a drop's pasteboard. First match wins:
    /// 1. files on disk;
    /// 2. file promises → received into a fresh drop directory;
    /// 3. image data with no file → written there as a PNG;
    /// 4. text or a link.
    /// `completion` runs on the main queue — straight away unless promises are
    /// pending — with nil when nothing usable was dropped.
    static func resolve(
        from pasteboard: NSPasteboard,
        dropDirectory: @escaping () -> URL? = makeDropDirectory,
        completion: @escaping (Content?) -> Void
    ) {
        let fileURLs = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        if !fileURLs.isEmpty {
            completion(.files(fileURLs))
            return
        }

        // Read the fallbacks now, while the drag pasteboard still holds this drop.
        let text = droppedText(from: pasteboard)
        let imageData = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)
        func fallback(in directory: URL?) -> Content? {
            // A browser image drag carries the image's address as its text; a text
            // selection that also offers an image flavour keeps its text.
            if let imageData, text.map(isWebAddress) ?? true,
               let directory = directory ?? dropDirectory(),
               let url = writePNG(imageData: imageData, to: directory, name: "dropped-image.png") {
                return .files([url])
            }
            return text.map(Content.text)
        }

        let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil)
            as? [NSFilePromiseReceiver] ?? []
        guard !receivers.isEmpty, let directory = dropDirectory() else {
            completion(fallback(in: nil))
            return
        }
        PromiseCollector(receivers: receivers, directory: directory) { urls in
            completion(urls.isEmpty ? fallback(in: directory) : .files(urls))
        }.start()
    }

    /// `resolve`, as the text typing the drop would produce.
    static func resolveText(
        from pasteboard: NSPasteboard,
        dropDirectory: @escaping () -> URL? = makeDropDirectory,
        completion: @escaping (String?) -> Void
    ) {
        resolve(from: pasteboard, dropDirectory: dropDirectory) { completion($0.map(text(for:))) }
    }

    /// Deliver a resolved drop to `station`. In a pane whose agent pastes images
    /// itself, dropped images attach through that paste and any other files
    /// follow as paths; everywhere else the drop is typed.
    static func deliver(_ content: Content, to station: Station) {
        guard case .files(let urls) = content,
              urls.contains(where: AgentImagePaste.isImage),
              AgentImagePaste.supports(AgentRegistry.shared.pane(for: station.id)?.agentType) else {
            station.sendText(text(for: content))
            return
        }
        AgentImagePaste.attach(urls, to: station) { [weak station] notAttached in
            guard let station, !notAttached.isEmpty else { return }
            station.sendText(pathsText(notAttached))
        }
    }

    /// The text a drop types: escaped paths, or the dropped text verbatim.
    static func text(for content: Content) -> String {
        switch content {
        case .files(let urls): return pathsText(urls)
        case .text(let text): return text
        }
    }

    /// Escaped paths joined by spaces, with a trailing space so a second drop
    /// doesn't run into the first.
    static func pathsText(_ urls: [URL]) -> String {
        urls.map { ShellEscape.backslash($0.path) }.joined(separator: " ") + " "
    }

    /// Every dropped item's text (or its link, for an item with no text), joined
    /// by spaces like native Ghostty. Nil when there is none.
    static func droppedText(from pasteboard: NSPasteboard) -> String? {
        let strings = (pasteboard.pasteboardItems ?? [])
            .compactMap { $0.string(forType: .string) ?? $0.string(forType: .URL) }
            .filter { !$0.isEmpty }
        return strings.isEmpty ? nil : strings.joined(separator: " ")
    }

    /// Whether dropped text is only an address — what a browser image drag
    /// carries as its text.
    static func isWebAddress(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace),
              let scheme = URL(string: trimmed)?.scheme?.lowercased() else { return false }
        return ["http", "https", "data", "blob", "file"].contains(scheme)
    }

    /// A fresh `$TMPDIR/seahelm-drops/<uuid>/`, so received files keep their own
    /// names without colliding. macOS purges `$TMPDIR`; nothing here cleans up.
    static func makeDropDirectory() -> URL? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("seahelm-drops", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        } catch {
            return nil
        }
    }

    /// Write PNG or TIFF image bytes to `directory/name` as a PNG. Also backs the
    /// composer's image paste (`GrowingTextView`).
    static func writePNG(imageData: Data, to directory: URL, name: String) -> URL? {
        guard let rep = NSBitmapImageRep(data: imageData),
              let pngData = rep.representation(using: .png, properties: [:]) else { return nil }
        let fileURL = directory.appendingPathComponent(name)
        do {
            try pngData.write(to: fileURL)
            return fileURL
        } catch {
            return nil
        }
    }
}

/// Receives a drop's file promises and reports the delivered files once, in
/// drop order — when the last reader returns, or at `promiseTimeout`.
private final class PromiseCollector {
    private let receivers: [NSFilePromiseReceiver]
    private let directory: URL
    private let completion: ([URL]) -> Void
    /// Only touched on main; the readers hop there.
    private var received: [[URL]]
    private var pending: [Int]
    private var finished = false
    /// The receivers do their coordinated reads here, off the main thread.
    private let workQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    init(receivers: [NSFilePromiseReceiver], directory: URL, completion: @escaping ([URL]) -> Void) {
        self.receivers = receivers
        self.directory = directory
        self.completion = completion
        received = Array(repeating: [], count: receivers.count)
        // One receiver can promise several files; its reader runs once per file.
        pending = receivers.map { max($0.fileTypes.count, 1) }
    }

    func start() {
        for (index, receiver) in receivers.enumerated() {
            receiver.receivePromisedFiles(atDestination: directory, options: [:], operationQueue: workQueue) { url, error in
                DispatchQueue.main.async {
                    if error == nil { self.received[index].append(url) }
                    self.pending[index] -= 1
                    if self.pending.allSatisfy({ $0 <= 0 }) { self.finish() }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + TerminalDrop.promiseTimeout) { self.finish() }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        completion(received.flatMap { $0 })
    }
}

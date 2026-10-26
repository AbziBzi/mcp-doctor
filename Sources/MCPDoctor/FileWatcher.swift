import Foundation

/// Watches one file, following atomic replacements (write to a temporary file, then rename).
@MainActor
final class FileWatcher {
    /// A missing file usually belongs to a harness that was never used.
    private static let missingFileRetry: Duration = .seconds(120)
    private static let replacedFileRetry: Duration = .milliseconds(500)

    private let url: URL
    private let onChange: @MainActor () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var retry: Task<Void, Never>?

    init(url: URL, onChange: @escaping @MainActor () -> Void) {
        self.url = url
        self.onChange = onChange
        open()
    }

    private func open() {
        let descriptor = Darwin.open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            reopen(after: Self.missingFileRetry)
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename, .link],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            MainActor.assumeIsolated {
                guard let self, let source else { return }
                let replaced = !source.data.isDisjoint(with: [.delete, .rename, .link])
                self.onChange()
                if replaced {
                    source.cancel()
                    self.source = nil
                    self.reopen(after: Self.replacedFileRetry)
                }
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    private func reopen(after delay: Duration) {
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.open()
        }
    }
}

import Foundation
import Synchronization

public struct CommandResult: Sendable {
    public var exitStatus: Int32
    public var stdout: Data
    public var stderr: Data
    public var timedOut: Bool
    public var launchError: String?

    public var output: String { String(decoding: stdout, as: UTF8.self) }
    public var errorOutput: String { String(decoding: stderr, as: UTF8.self) }
    public var succeeded: Bool { launchError == nil && !timedOut && exitStatus == 0 }

    /// The most useful one-line explanation of a failure.
    public var failureSummary: String {
        if let launchError { return launchError }
        if timedOut { return "Timed out" }
        let text = [errorOutput, output]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return text?.split(separator: "\n").last.map(String.init) ?? "Exited with status \(exitStatus)"
    }
}

public enum CommandRunner {
    /// Runs a process without a terminal and collects its output.
    ///
    /// `onOutput` sees each stdout chunk as it arrives; returning `true` stops the process early.
    /// Cancelling the calling task terminates the process.
    public static func run(
        _ executable: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil,
        input: Data? = nil,
        keepInputOpen: Bool = false,
        timeout: TimeInterval,
        qualityOfService: QualityOfService = .utility,
        onOutput: (@Sendable (Data) -> Bool)? = nil
    ) async -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
        process.qualityOfService = qualityOfService

        let execution = Execution(
            process: process,
            input: input,
            keepInputOpen: keepInputOpen,
            timeout: timeout,
            onOutput: onOutput
        )
        return await withTaskCancellationHandler {
            await execution.start()
        } onCancel: {
            execution.stop()
        }
    }
}

/// One process run. Pipe handlers, the termination handler, the timeout and cancellation call in
/// from different threads, so the mutable state sits behind a mutex.
private final class Execution: Sendable {
    /// How long a terminated process gets before it's killed.
    private static let killDelay: TimeInterval = 2
    /// How long to wait for output after exit; a grandchild can hold the pipes open indefinitely.
    private static let outputGrace: TimeInterval = 0.5

    private struct State {
        var stdout = Data()
        var stderr = Data()
        var openStreams = 2
        var launched = false
        var exitStatus: Int32?
        var timedOut = false
        var stopRequested = false
        /// Set while a caller is waiting; taken exactly once to deliver the result.
        var continuation: CheckedContinuation<CommandResult, Never>?
    }

    private let process: Process
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stdinPipe = Pipe()
    private let input: Data?
    private let keepInputOpen: Bool
    private let timeout: TimeInterval
    private let onOutput: (@Sendable (Data) -> Bool)?
    private let state = Mutex(State())

    init(
        process: Process,
        input: Data?,
        keepInputOpen: Bool,
        timeout: TimeInterval,
        onOutput: (@Sendable (Data) -> Bool)?
    ) {
        self.process = process
        self.input = input
        self.keepInputOpen = keepInputOpen
        self.timeout = timeout
        self.onOutput = onOutput
    }

    func start() async -> CommandResult {
        await withCheckedContinuation { continuation in
            let cancelled = state.withLock { state in
                state.continuation = continuation
                return state.stopRequested
            }
            if cancelled {
                finish(launchError: "Cancelled")
            } else {
                launch()
            }
        }
    }

    func stop() {
        let running = state.withLock { state in
            state.stopRequested = true
            return state.launched && state.exitStatus == nil
        }
        guard running else { return }
        try? stdinPipe.fileHandleForWriting.close()
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.killDelay) { [weak self] in
            if self?.state.withLock({ $0.exitStatus == nil }) == true { kill(pid, SIGKILL) }
        }
    }

    private func launch() {
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = input == nil ? FileHandle.nullDevice : stdinPipe
        stdoutPipe.fileHandleForReading.readabilityHandler = { [self] in read($0, isStdout: true) }
        stderrPipe.fileHandleForReading.readabilityHandler = { [self] in read($0, isStdout: false) }
        process.terminationHandler = { [self] in exited(with: $0.terminationStatus) }

        do {
            try process.run()
        } catch {
            detachHandlers()
            finish(launchError: error.localizedDescription)
            return
        }
        let stopRequested = state.withLock { state in
            state.launched = true
            return state.stopRequested
        }
        if stopRequested { stop() }

        if let input {
            let handle = stdinPipe.fileHandleForWriting
            try? handle.write(contentsOf: input)
            if !keepInputOpen { try? handle.close() }
        }

        // Weak, so a finished run and its output aren't kept alive until the timeout.
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.timeoutElapsed()
        }
    }

    private func timeoutElapsed() {
        let running = state.withLock { state in
            guard state.exitStatus == nil else { return false }
            state.timedOut = true
            return true
        }
        if running { stop() }
    }

    private func read(_ handle: FileHandle, isStdout: Bool) {
        let data = handle.availableData
        guard !data.isEmpty else {
            handle.readabilityHandler = nil
            state.withLock { $0.openStreams -= 1 }
            finishIfDone(waitForOutput: true)
            return
        }
        state.withLock { state in
            if isStdout { state.stdout.append(data) } else { state.stderr.append(data) }
        }
        if isStdout, onOutput?(data) == true { stop() }
    }

    private func exited(with status: Int32) {
        state.withLock { $0.exitStatus = status }
        finishIfDone(waitForOutput: true)
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.outputGrace) { [weak self] in
            self?.finishIfDone(waitForOutput: false)
        }
    }

    private func finishIfDone(waitForOutput: Bool) {
        let delivery: (CheckedContinuation<CommandResult, Never>, CommandResult)? = state.withLock { state in
            guard let status = state.exitStatus,
                  !waitForOutput || state.openStreams == 0,
                  let continuation = state.continuation
            else { return nil }
            state.continuation = nil
            let result = CommandResult(
                exitStatus: status,
                stdout: state.stdout,
                stderr: state.stderr,
                timedOut: state.timedOut,
                launchError: nil
            )
            return (continuation, result)
        }
        guard let (continuation, result) = delivery else { return }
        detachHandlers()
        continuation.resume(returning: result)
    }

    private func finish(launchError: String) {
        let continuation = state.withLock { state in
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(returning: CommandResult(
            exitStatus: -1,
            stdout: Data(),
            stderr: Data(),
            timedOut: false,
            launchError: launchError
        ))
    }

    /// The handlers capture `self`; clearing them ends that cycle.
    private func detachHandlers() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
    }
}

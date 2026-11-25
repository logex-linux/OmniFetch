import Foundation

public struct ProcessResult: Sendable {
    public let code: Int32
    public let stdout: String
    public let stderr: String

    public var succeeded: Bool { code == 0 }
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
    let lock = NSLock()
    func append(_ chunk: Data) {
        lock.lock(); data.append(chunk); lock.unlock()
    }
    func value() -> Data {
        lock.lock(); defer { lock.unlock() }; return data
    }
}

public enum Shell {
    /// Runs a process and captures stdout/stderr without deadlocking on full pipes.
    public static func run(_ launchPath: String,
                           _ args: [String],
                           cwd: URL? = nil,
                           env: [String: String]? = nil,
                           timeout: TimeInterval? = nil) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = cwd }
        var environment = env ?? ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "OMNIFETCH_X_BEARER_TOKEN")
        environment.removeValue(forKey: "OMNI_COOKIE")
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        // Children must never read the app's stdin (ffmpeg blocks on it).
        process.standardInput = FileHandle.nullDevice

        let outBox = DataBox()
        let errBox = DataBox()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            outBox.append(data)
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            errBox.append(data)
            group.leave()
        }

        let box = ProcessBox(process)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { proc in
                    // A grandchild can keep the pipe open after the child exits;
                    // never block the continuation forever on a full drain.
                    _ = group.wait(timeout: .now() + 5)
                    let result = ProcessResult(
                        code: proc.terminationStatus,
                        stdout: String(decoding: outBox.value(), as: UTF8.self),
                        stderr: String(decoding: errBox.value(), as: UTF8.self)
                    )
                    continuation.resume(returning: result)
                }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                if Task.isCancelled { box.terminate() }
                if let timeout {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                        guard process.isRunning else { return }
                        process.terminate()
                        // SIGTERM can be ignored; make the timeout actually bound.
                        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                        }
                    }
                }
            }
        } onCancel: {
            // Pausing during an ffmpeg merge must stop the merge, not wait it out.
            box.terminate()
        }
    }

    public static func which(_ name: String) -> String? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let fm = FileManager.default
        for dir in paths {
            let candidate = dir + "/" + name
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

private final class ProcessBox: @unchecked Sendable {
    private let process: Process
    init(_ process: Process) { self.process = process }
    func terminate() {
        if process.isRunning { process.terminate() }
    }
}

private final class AtomicOnce: @unchecked Sendable {
    private var used = false
    private let lock = NSLock()
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}

/// Long-running process whose stdout is consumed line by line (yt-dlp progress).
public final class StreamingProcess: @unchecked Sendable {
    public let process = Process()
    private let pipe = Pipe()
    private var buffer = Data()
    private let lock = NSLock()

    private let input: Data?
    private let inputPipe: Pipe?

    public init(executable: String, arguments: [String], cwd: URL? = nil, env: [String: String]? = nil, input: Data? = nil) {
        self.input = input
        self.inputPipe = input == nil ? nil : Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }
        var environment = env ?? ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "OMNIFETCH_X_BEARER_TOKEN")
        environment.removeValue(forKey: "OMNI_COOKIE")
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = pipe
        if let inputPipe { process.standardInput = inputPipe }
        else { process.standardInput = FileHandle.nullDevice }
    }

    public func start() throws {
        try process.run()
        if let input, let writer = inputPipe?.fileHandleForWriting {
            _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
            DispatchQueue.global(qos: .utility).async {
                defer { try? writer.close() }
                try? writer.write(contentsOf: input)
            }
        }
    }

    public var isRunning: Bool { process.isRunning }

    public func terminate() {
        if process.isRunning { process.terminate() }
    }

    public func waitUntilExit() async -> Int32 {
        await withCheckedContinuation { cont in
            let resumed = AtomicOnce()
            process.terminationHandler = { proc in
                if resumed.claim() { cont.resume(returning: proc.terminationStatus) }
            }
            // The process may already be gone; the handler then never fires
            // (or fires immediately), so resume exactly once here as well.
            if !process.isRunning, resumed.claim() {
                cont.resume(returning: process.terminationStatus)
            }
        }
    }

    /// Lines are split on \n and \r, which covers yt-dlp's progress output.
    public func lines() -> AsyncStream<String> {
        AsyncStream { continuation in
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                guard let self else { return }
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    self.lock.lock()
                    let tail = String(data: self.buffer, encoding: .utf8)
                    self.buffer.removeAll()
                    self.lock.unlock()
                    if let tail, !tail.isEmpty { continuation.yield(tail) }
                    continuation.finish()
                    return
                }
                self.lock.lock()
                self.buffer.append(chunk)
                var lines: [String] = []
                while let idx = self.buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                    let lineData = self.buffer[self.buffer.startIndex..<idx]
                    self.buffer.removeSubrange(self.buffer.startIndex...idx)
                    if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                        lines.append(line)
                    }
                }
                self.lock.unlock()
                for line in lines { continuation.yield(line) }
            }
            continuation.onTermination = { [weak self] _ in
                self?.pipe.fileHandleForReading.readabilityHandler = nil
            }
        }
    }
}

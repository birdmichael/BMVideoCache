import Foundation
public actor BMLogger {
    static let shared = BMLogger()
    public enum LogLevel: Int, Comparable {
        case trace = -1
        case debug = 0
        case info = 1
        case warning = 2
        case error = 3
        case none = 4
        public static func < (lhs: BMLogger.LogLevel, rhs: BMLogger.LogLevel) -> Bool {
            return lhs.rawValue < rhs.rawValue
        }
    }
    var currentLevel: LogLevel = .info
    var disableFileLoggingOnError: Bool = true
    private let dateFormatter: DateFormatter
    private var isFileLoggingEnabled: Bool = false
    private var logFileURL: URL?
    private var logFileHandle: FileHandle?
    private init() {
        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    }
    deinit {}
    public func setLogLevel(_ level: LogLevel) {
        self.currentLevel = level
    }
    func setupFileLogging(enabled: Bool, fileURL: URL? = nil) async {
        await closeLogFile()
        self.isFileLoggingEnabled = enabled
        self.logFileURL = nil
        self.logFileHandle = nil
        guard enabled, let url = fileURL else {
            await self.info("File logging disabled.")
            return
        }
        self.logFileURL = url
        let fileManager = FileManager.default
        let directoryURL = url.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
            if !fileManager.fileExists(atPath: url.path) {
                fileManager.createFile(atPath: url.path, contents: nil, attributes: nil)
            }
            self.logFileHandle = try FileHandle(forUpdating: url)

            try self.logFileHandle?.seekToEnd()

            if let handle = self.logFileHandle {
                await fileWriteActor.startPeriodicFlush(handle: handle)
            }
            await self.info("File logging enabled at: \(url.path)")
        } catch {
            self.isFileLoggingEnabled = false
            self.logFileURL = nil
            self.logFileHandle = nil
        }
    }
    private func closeLogFile() async {
        if let handle = logFileHandle {
            await fileWriteActor.stopPeriodicFlush()
            try? handle.synchronize()
            try? handle.close()
            logFileHandle = nil
            logFileURL = nil
        }
    }
    private actor FileWriteActor {
        private var pendingWrites: [Data] = []
        private var isProcessingWrites = false
        private var writeTimer: Task<Void, Error>? = nil
        func writeToFile(handle: FileHandle, data: Data) async throws {
            pendingWrites.append(data)
            if !isProcessingWrites {
                isProcessingWrites = true
                try await processWrites(handle: handle)
                isProcessingWrites = false
            }
        }
        private func processWrites(handle: FileHandle) async throws {
            try? await Task.sleep(nanoseconds: 10_000_000)
            let writesToProcess = pendingWrites
            pendingWrites = []
            if !writesToProcess.isEmpty {
                let combinedData = writesToProcess.reduce(Data()) { $0 + $1 }
                try handle.seekToEnd()
                try handle.write(contentsOf: combinedData)
            }
            if !pendingWrites.isEmpty {
                try await processWrites(handle: handle)
            }
        }
        func startPeriodicFlush(handle: FileHandle) {
            writeTimer?.cancel()
            writeTimer = Task {
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    if !pendingWrites.isEmpty && !isProcessingWrites {
                        isProcessingWrites = true
                        try await processWrites(handle: handle)
                        isProcessingWrites = false
                    }
                }
            }
        }
        func stopPeriodicFlush() {
            writeTimer?.cancel()
            writeTimer = nil
        }
    }
    private let fileWriteActor = FileWriteActor()
    private func log(level: LogLevel, message: @autoclosure () -> Any, file: String = #file, function: String = #function, line: Int = #line) async {
        guard level >= currentLevel else { return }
        let msgValue = message()
        let timestamp = self.dateFormatter.string(from: Date())
        let fileName = (file as NSString).lastPathComponent
        let levelString: String
        switch level {
        case .trace: levelString = "TRACE"
        case .debug: levelString = "DEBUG"
        case .info: levelString = "INFO "
        case .warning: levelString = "WARN "
        case .error: levelString = "ERROR"
        case .none: return
        }
        let logMessage = "\(timestamp) [BMVideoCache] [\(levelString)] [\(fileName):\(line)] \(function) - \(msgValue)"
        print(logMessage)
        if self.isFileLoggingEnabled, let handle = self.logFileHandle, let data = (logMessage + "\n").data(using: .utf8) {
            do {
                try await fileWriteActor.writeToFile(handle: handle, data: data)
            } catch {
                if self.disableFileLoggingOnError {
                    self.isFileLoggingEnabled = false
                    Task { await self.closeLogFile() }
                }
            }
        }
    }
    func trace(_ message: @autoclosure () -> Any, file: String = #file, function: String = #function, line: Int = #line) async {
        await log(level: .trace, message: message(), file: file, function: function, line: line)
    }
    public func getLogLevel() -> LogLevel {
        return self.currentLevel
    }
    func debug(_ message: @autoclosure () -> Any, file: String = #file, function: String = #function, line: Int = #line) async {
        await log(level: .debug, message: message(), file: file, function: function, line: line)
    }
    func info(_ message: @autoclosure () -> Any, file: String = #file, function: String = #function, line: Int = #line) async {
        await log(level: .info, message: message(), file: file, function: function, line: line)
    }
    func warning(_ message: @autoclosure () -> Any, file: String = #file, function: String = #function, line: Int = #line) async {
        await log(level: .warning, message: message(), file: file, function: function, line: line)
    }
    func error(_ message: @autoclosure () -> Any, file: String = #file, function: String = #function, line: Int = #line) async {
        await log(level: .error, message: message(), file: file, function: function, line: line)
    }
    func performance(_ operation: String, durationMs: Double, file: String = #file, function: String = #function, line: Int = #line) async {
        await log(level: .debug, message: "PERFORMANCE: \(operation) took \(String(format: "%.2f", durationMs))ms", file: file, function: function, line: line)
    }
    nonisolated func performanceSync(_ operation: String, durationMs: Double, file: String = #file, function: String = #function, line: Int = #line) {
        Task { await performance(operation, durationMs: durationMs, file: file, function: function, line: line) }
    }
    nonisolated func traceSync(_ message: Any, file: String = #file, function: String = #function, line: Int = #line) {
        Task { await log(level: .trace, message: message, file: file, function: function, line: line) }
    }
    nonisolated func debugSync(_ message: Any, file: String = #file, function: String = #function, line: Int = #line) {
        Task { await log(level: .debug, message: message, file: file, function: function, line: line) }
    }
    nonisolated func infoSync(_ message: Any, file: String = #file, function: String = #function, line: Int = #line) {
        Task { await log(level: .info, message: message, file: file, function: function, line: line) }
    }
    nonisolated func warningSync(_ message: Any, file: String = #file, function: String = #function, line: Int = #line) {
        Task { await log(level: .warning, message: message, file: file, function: function, line: line) }
    }
    nonisolated func errorSync(_ message: Any, file: String = #file, function: String = #function, line: Int = #line) {
        Task { await log(level: .error, message: message, file: file, function: function, line: line) }
    }
}

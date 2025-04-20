import Foundation

public class BMLogger {
    private var fileLoggingEnabled: Bool = false
    private var logFileURL: URL?
    private let fileQueue = DispatchQueue(label: "BMLogger.FileQueue")

    /// 启用/禁用文件日志
    public func setupFileLogging(enabled: Bool, fileURL: URL?) {
        self.fileLoggingEnabled = enabled
        self.logFileURL = fileURL
        if enabled, let url = fileURL {
            // 创建空文件或追加模式打开
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil, attributes: nil)
            }
        }
    }
    public enum LogLevel: Int {
        case trace = 0
        case debug = 1
        case info = 2
        case warning = 3
        case error = 4
        case none = 5
    }

    public static let shared = BMLogger()
    private var currentLevel: LogLevel = .debug
    private init() {}

    public func setLogLevel(_ level: LogLevel) {
        self.currentLevel = level
    }

    public func getLogLevel() -> LogLevel {
        return self.currentLevel
    }

    private func writeToFile(_ message: String) {
        guard fileLoggingEnabled, let url = logFileURL else { return }
        fileQueue.async {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                if let data = (message + "\n").data(using: .utf8) {
                    handle.write(data)
                }
                try? handle.close()
            }
        }
    }

    public func trace(_ message: @autoclosure () -> Any) {
#if DEBUG
        if currentLevel.rawValue <= LogLevel.trace.rawValue {
            let msg = "[TRACE] \(message())"
            print(msg)
            writeToFile(msg)
        }
#endif
    }

    public func debug(_ message: @autoclosure () -> Any) {
#if DEBUG
        if currentLevel.rawValue <= LogLevel.debug.rawValue {
            let msg = "[DEBUG] \(message())"
            print(msg)
            writeToFile(msg)
        }
#endif
    }
    public func info(_ message: @autoclosure () -> Any) {
#if DEBUG
        if currentLevel.rawValue <= LogLevel.info.rawValue {
            let msg = "[INFO] \(message())"
            print(msg)
            writeToFile(msg)
        }
#endif
    }
    public func warning(_ message: @autoclosure () -> Any) {
#if DEBUG
        if currentLevel.rawValue <= LogLevel.warning.rawValue {
            let msg = "[WARNING] \(message())"
            print(msg)
            writeToFile(msg)
        }
#endif
    }
    public func error(_ message: @autoclosure () -> Any) {
#if DEBUG
        if currentLevel.rawValue <= LogLevel.error.rawValue {
            let msg = "[ERROR] \(message())"
            print(msg)
            writeToFile(msg)
        }
#endif
    }
}



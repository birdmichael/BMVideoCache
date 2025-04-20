import Foundation
import os
internal actor BMFileHandleManager {
    private let fileURL: URL
    private let fileManager = FileManager.default
    private var readFileHandle: FileHandle?
    private var writeFileHandle: FileHandle?
    init(fileURL: URL) throws {
        self.fileURL = fileURL
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        if !fileManager.fileExists(atPath: fileURL.path) {
            if !fileManager.createFile(atPath: fileURL.path, contents: nil, attributes: nil) {
                throw FileHandleError.fileCreationFailed(path: fileURL.path)
            }
        }
        do {
            self.readFileHandle = try FileHandle(forReadingFrom: fileURL)
            self.writeFileHandle = try FileHandle(forWritingTo: fileURL)
        } catch {
            throw FileHandleError.handleCreationFailed(underlyingError: error)
        }
    }
    deinit {
        do {
            if let writeHandle = writeFileHandle {
                if #available(iOS 13.4, macOS 10.15.4, tvOS 13.4, watchOS 6.2, *) {
                    try writeHandle.synchronize()
                } else {
                    writeHandle.synchronizeFile()
                }
                try writeHandle.close()
            }
            try readFileHandle?.close()
        } catch {
        }
    }
    func close() async {
        do {
            if let writeHandle = writeFileHandle {
                if #available(iOS 13.4, macOS 10.15.4, tvOS 13.4, watchOS 6.2, *) {
                    try writeHandle.synchronize()
                } else {
                    writeHandle.synchronizeFile()
                }
                try writeHandle.close()
                writeFileHandle = nil
            }
            if let readHandle = readFileHandle {
                try readHandle.close()
                readFileHandle = nil
            }
            Task { BMLogger.shared.debug("Synchronized and closed file handles for \(fileURL.lastPathComponent)") }
        } catch {
            Task { BMLogger.shared.error("Error synchronizing/closing file handle for \(fileURL.lastPathComponent): \(error)") }
        }
    }
    func readData(offset: Int64, length: Int) async -> Data? {
        guard let handle = self.readFileHandle else {
            return nil
        }
        do {
            if #available(iOS 13.4, macOS 10.15.4, tvOS 13.4, watchOS 6.2, *) {
                try handle.seek(toOffset: UInt64(offset))
                return try handle.read(upToCount: length)
            } else {
                handle.seek(toFileOffset: UInt64(offset))
                return handle.readData(ofLength: length)
            }
        } catch {
            return nil
        }
    }
    func writeData(_ data: Data, at offset: Int64) async {
        // 首先检查文件句柄
        guard let handle = self.writeFileHandle else {
            Task { BMLogger.shared.error("Write attempt with nil writeFileHandle for \(self.fileURL.lastPathComponent)") }

            // 尝试重新创建文件句柄
            do {
                self.writeFileHandle = try FileHandle(forWritingTo: fileURL)
                Task { BMLogger.shared.info("Re-created write file handle for \(self.fileURL.lastPathComponent)") }
                // 递归调用以使用新创建的句柄
                await writeData(data, at: offset)
                return
            } catch {
                Task { BMLogger.shared.error("Failed to re-create write file handle for \(self.fileURL.lastPathComponent): \(error)") }
                return
            }
        }

        // 尝试写入数据
        do {
            if #available(iOS 13.4, macOS 10.15.4, tvOS 13.4, watchOS 6.2, *) {
                try handle.seek(toOffset: UInt64(offset))
                try handle.write(contentsOf: data)
                // 每次写入后都同步到磁盘，确保数据不会丢失
                try handle.synchronize()
                Task { BMLogger.shared.debug("Successfully wrote and synchronized \(data.count) bytes at offset \(offset) for \(self.fileURL.lastPathComponent)") }
            } else {
                handle.seek(toFileOffset: UInt64(offset))
                handle.write(data)
                handle.synchronizeFile()
                Task { BMLogger.shared.debug("Successfully wrote and synchronized \(data.count) bytes at offset \(offset) for \(self.fileURL.lastPathComponent)") }
            }

            // 验证文件存在
            let fileManager = FileManager.default
            if !fileManager.fileExists(atPath: fileURL.path) {
                Task { BMLogger.shared.error("File does not exist after write: \(fileURL.path)") }
            }
        } catch {
            Task { BMLogger.shared.error("Error writing data at offset \(offset) for file \(self.fileURL.lastPathComponent): \(error)") }

            // 尝试直接写入文件
            do {
                try data.write(to: fileURL, options: .atomic)
                Task { BMLogger.shared.info("Fallback: Successfully wrote \(data.count) bytes directly to file \(self.fileURL.lastPathComponent)") }
            } catch {
                Task { BMLogger.shared.error("Fallback write also failed for \(self.fileURL.lastPathComponent): \(error)") }
            }
        }
    }
    func synchronize() async {
        guard let handle = self.writeFileHandle else { return }
        do {
            if #available(iOS 13.4, macOS 10.15.4, tvOS 13.4, watchOS 6.2, *) {
                try handle.synchronize()
                Task { BMLogger.shared.debug("Synchronized file handle for \(fileURL.lastPathComponent)") }
            } else {
                handle.synchronizeFile()
                Task { BMLogger.shared.debug("Synchronized file handle for \(fileURL.lastPathComponent)") }
            }
        } catch {
            Task { BMLogger.shared.error("Failed to synchronize file handle for \(fileURL.lastPathComponent): \(error)") }
        }
    }
    enum FileHandleError: Error {
        case fileCreationFailed(path: String)
        case handleCreationFailed(underlyingError: Error)
    }
}

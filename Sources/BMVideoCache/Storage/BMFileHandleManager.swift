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
            Task { await BMLogger.shared.debug("Synchronized and closed file handles for \(fileURL.lastPathComponent)") }
        } catch {
            Task { await BMLogger.shared.error("Error synchronizing/closing file handle for \(fileURL.lastPathComponent): \(error)") }
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
        guard let handle = self.writeFileHandle else {
            Task { await BMLogger.shared.error("Write attempt with nil writeFileHandle for \(self.fileURL.lastPathComponent)") }
            return
        }
        do {
            if #available(iOS 13.4, macOS 10.15.4, tvOS 13.4, watchOS 6.2, *) {
                try handle.seek(toOffset: UInt64(offset))
                try handle.write(contentsOf: data)
                if arc4random_uniform(10) == 0 {
                    try handle.synchronize()
                }
            } else {
                handle.seek(toFileOffset: UInt64(offset))
                handle.write(data)
                if arc4random_uniform(10) == 0 {
                    handle.synchronizeFile()
                }
            }
        } catch {
            Task { await BMLogger.shared.error("Error writing data at offset \(offset) for file \(self.fileURL.lastPathComponent): \(error)") }
        }
    }
    func synchronize() async {
        guard let handle = self.writeFileHandle else { return }
        do {
           try handle.synchronize()
        } catch {
        }
    }
    enum FileHandleError: Error {
        case fileCreationFailed(path: String)
        case handleCreationFailed(underlyingError: Error)
    }
}

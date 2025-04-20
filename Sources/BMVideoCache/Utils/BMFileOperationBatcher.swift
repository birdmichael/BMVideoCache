import Foundation
actor BMFileOperationBatcher {
    static let shared = BMFileOperationBatcher()

    private struct FilePair {
        let cacheFile: URL
        let metadataFile: URL
        let key: String
    }

    private var pendingDeletions: [FilePair] = []
    private var isProcessingDeletions = false
    private var batchTimer: Task<Void, Error>?
    private let batchSize = 10
    private let batchInterval: UInt64 = 1_000_000_000

    private init() {
        Task {
            await startBatchProcessingTask()
        }
    }

    deinit {
        batchTimer?.cancel()
    }

    private func startBatchProcessingTask() async {
        batchTimer = Task {
            await startBatchProcessing()
        }
    }

    private func startBatchProcessing() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: batchInterval)
                if !pendingDeletions.isEmpty && !isProcessingDeletions {
                    await processBatch()
                }
            } catch {
                break
            }
        }
    }
    func queueFilesForDeletion(cacheFile: URL, metadataFile: URL, key: String) {
        pendingDeletions.append(FilePair(cacheFile: cacheFile, metadataFile: metadataFile, key: key))

        if pendingDeletions.count >= batchSize && !isProcessingDeletions {
            Task {
                await processBatch()
            }
        }
    }

    private func processBatch() async {
        guard !pendingDeletions.isEmpty && !isProcessingDeletions else { return }

        isProcessingDeletions = true

        let currentBatch = Array(pendingDeletions.prefix(batchSize))
        pendingDeletions.removeFirst(min(batchSize, pendingDeletions.count))

        var deletedCount = 0
        var errorCount = 0

        for filePair in currentBatch {
            await Task.yield()

            do {
                // 确保缓存文件目录存在
                let cacheDir = filePair.cacheFile.deletingLastPathComponent()
                if !FileManager.default.fileExists(atPath: cacheDir.path) {
                    try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
                    BMLogger.shared.debug("Created cache directory for batch deletion: \(cacheDir.path)")
                }

                if FileManager.default.fileExists(atPath: filePair.cacheFile.path) {
                    try FileManager.default.removeItem(at: filePair.cacheFile)
                    deletedCount += 1
                }

                await Task.yield()

                if FileManager.default.fileExists(atPath: filePair.metadataFile.path) {
                    try FileManager.default.removeItem(at: filePair.metadataFile)
                    deletedCount += 1
                }
            } catch {
                errorCount += 1
                BMLogger.shared.error("Error deleting files for key \(filePair.key): \(error)")
            }
        }

        if deletedCount > 0 || errorCount > 0 {
            BMLogger.shared.debug("Batch file deletion: processed \(currentBatch.count) items, deleted \(deletedCount) files, \(errorCount) errors")
        }

        isProcessingDeletions = false

        if pendingDeletions.count >= batchSize {
            await processBatch()
        }
    }
}

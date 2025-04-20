import Foundation
import Combine
import CryptoKit

public actor BMCacheManager {
    // 推送式进度回调（可选） - 添加了 originalURL 参数
    public var onProgress: ((_ key: String, _ originalURL: URL, _ progress: Double, _ currentSize: UInt64, _ totalExpected: UInt64) -> Void)?

    internal let configuration: BMCacheConfiguration
    private let metadataEncoder = PropertyListEncoder()
    private let metadataDecoder = PropertyListDecoder()
    private var currentCacheSize: UInt64 = 0
    private weak var dataLoaderManager: (any BMDataLoaderManaging)?
    private var batchedWriteBuffer: [String: [(offset: Int64, data: Data)]] = [:]
    private var lastBatchedWriteTime: [String: TimeInterval] = [:]
    // 统计数据
    private var cacheStatistics = BMCacheStatistics()
    private var lastStatsUpdateTime: Date = .distantPast
    private let statsDebounceInterval: TimeInterval = 3.0 // 3秒防抖间隔

    private let batchWriteInterval: TimeInterval = 0.5
    private let integrityCheckQueue = DispatchQueue(label: "com.bmvideocache.fileintegrity.queue", attributes: .concurrent)

    // ================== 内部类型 ==================
    private actor MetadataStore {
        var dict: [String: BMCacheMetadata] = [:]
        func get(_ key: String) -> BMCacheMetadata? { dict[key] }
        func set(_ metadata: BMCacheMetadata, for key: String) { dict[key] = metadata }
        func remove(_ key: String) { dict.removeValue(forKey: key) }
        func getAllValues() -> [BMCacheMetadata] { Array(dict.values) }
        func count() -> Int { dict.count }
    }
    private let metadataStore = MetadataStore()

    private actor FileHandleActor {
        var handles: [String: BMFileHandleManager] = [:]

        func getHandle(forKey key: String, createWith fileURL: URL) async throws -> BMFileHandleManager {
            if let existingHandle = handles[key] { return existingHandle }
            let directoryURL = fileURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: directoryURL.path) {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                BMLogger.shared.debug("Created cache data directory.")
            }
            let newHandle = try BMFileHandleManager(fileURL: fileURL)
            handles[key] = newHandle
            BMLogger.shared.debug("Created file handle for key: \(key)")
            return newHandle
        }

        func removeHandle(forKey key: String) {
            if handles.removeValue(forKey: key) != nil {
                BMLogger.shared.debug("Removed file handle for key: \(key)")
            }
        }
    }
    private let fileHandleActor = FileHandleActor()


    public init(configuration: BMCacheConfiguration) {
        self.configuration = configuration
        BMLogger.shared.info("BMCacheManager initialized.")
    }

    // MARK: - Static Factory (Simplified)
    public static func create(configuration: BMCacheConfiguration) async -> BMCacheManager {
        let manager = BMCacheManager(configuration: configuration)
        await manager._loadMetadataAsync() // Load existing metadata
        await manager._calculateInitialCacheSizeAsync() // Calculate initial size
        await manager._loadStatisticsAsync() // Load existing statistics
        // TODO: Start cleanup/monitoring timers later
        return manager
    }

    // MARK: - Internal Setup Methods
    private func _loadMetadataAsync() async {
        // 使用与 saveMetadata 相同的方式获取元数据目录
        let metadataDir = configuration.metadataFileURL(for: "dummy").deletingLastPathComponent()
        BMLogger.shared.info("_loadMetadataAsync: 开始加载元数据目录 \(metadataDir.path)")

        do {
            // 确保元数据目录存在
            if !FileManager.default.fileExists(atPath: metadataDir.path) {
                try FileManager.default.createDirectory(at: metadataDir, withIntermediateDirectories: true)
                BMLogger.shared.info("Metadata directory doesn't exist, created empty directory.")
            }

            let fileURLs = try FileManager.default.contentsOfDirectory(at: metadataDir, includingPropertiesForKeys: nil)
            let metadataFiles = fileURLs.filter { $0.pathExtension == configuration.metadataFileExtension }

            guard !metadataFiles.isEmpty else {
                BMLogger.shared.info("No existing metadata files found.")
                return
            }

            var loadedCount = 0
            var validatedCount = 0
            for fileURL in metadataFiles {
                do {
                    let data = try Data(contentsOf: fileURL)
                    var metadata = try self.metadataDecoder.decode(BMCacheMetadata.self, from: data)
                    let key = fileURL.deletingPathExtension().lastPathComponent
                    // 修正 cacheKey
                    metadata = BMCacheMetadata(cacheKey: key, originalURL: metadata.originalURL, contentInfo: metadata.contentInfo)

                    // 验证缓存文件是否存在并更新元数据
                    let cacheFileURL = configuration.cacheFileURL(for: key)
                    if FileManager.default.fileExists(atPath: cacheFileURL.path) {
                        // 获取实际文件大小
                        if let attrs = try? FileManager.default.attributesOfItem(atPath: cacheFileURL.path),
                           let fileSize = attrs[.size] as? UInt64 {

                            // 如果文件存在但元数据不完整，更新元数据
                            if !metadata.isComplete || metadata.totalCachedSize != fileSize {
                                metadata.isComplete = true
                                metadata.totalCachedSize = fileSize

                                // 如果没有内容长度信息，添加它
                                if metadata.contentInfo == nil || metadata.contentInfo?.contentLength == 0 {
                                    metadata.contentInfo = BMContentInfo(
                                        contentType: "video/mp4",
                                        contentLength: Int64(fileSize),
                                        isByteRangeAccessSupported: true
                                    )
                                }

                                // 更新缓存范围
                                if metadata.cachedRanges.isEmpty && fileSize > 0 {
                                    metadata.cachedRanges = [ClosedRange(uncheckedBounds: (lower: 0, upper: Int64(fileSize) - 1))]
                                }

                                // 保存更新后的元数据
                                try? self.metadataEncoder.encode(metadata).write(to: fileURL, options: .atomic)
                                BMLogger.shared.info("Updated metadata for existing file: \(key), size: \(fileSize)")
                            }
                            validatedCount += 1
                        } else {
                            BMLogger.shared.warning("File exists but couldn't get size for: \(cacheFileURL.path)")
                        }
                    } else if metadata.isComplete {
                        // 文件不存在但元数据显示完成，重置元数据
                        metadata.isComplete = false
                        metadata.totalCachedSize = 0
                        metadata.cachedRanges = []

                        // 保存更新后的元数据
                        try? self.metadataEncoder.encode(metadata).write(to: fileURL, options: .atomic)
                        BMLogger.shared.info("Reset metadata for missing file: \(key)")
                    }

                    await metadataStore.set(metadata, for: key)
                    loadedCount += 1
                } catch {
                    BMLogger.shared.error("Failed to load or decode metadata file \(fileURL.lastPathComponent): \(error)")
                    // Optionally remove corrupt metadata file
                    // try? FileManager.default.removeItem(at: fileURL)
                }
            }
            BMLogger.shared.info("Successfully loaded \(loadedCount) metadata entries, validated \(validatedCount) cache files.")

        } catch CocoaError.fileReadNoSuchFile {
            BMLogger.shared.info("Metadata directory doesn't exist, no metadata loaded.")
        } catch {
            BMLogger.shared.error("Failed to list metadata directory \(metadataDir.path): \(error)")
        }
    }

    private func _calculateInitialCacheSizeAsync() async {
        let allMetadata = await metadataStore.getAllValues()
        let totalSize = allMetadata.reduce(UInt64(0)) { $0 + $1.totalCachedSize }
        self.currentCacheSize = totalSize
        BMLogger.shared.info("Calculated initial cache size: \(totalSize) bytes from \(allMetadata.count) items.")
    }

    // 加载统计数据
    private func _loadStatisticsAsync() async {
        let statsFileURL = configuration.cacheDirectoryURL.appendingPathComponent("statistics.plist")

        do {
            if FileManager.default.fileExists(atPath: statsFileURL.path) {
                let data = try Data(contentsOf: statsFileURL)
                let loadedStats = try PropertyListDecoder().decode(BMCacheStatistics.self, from: data)
                self.cacheStatistics = loadedStats
                BMLogger.shared.info("Loaded cache statistics: \(loadedStats.hitCount) hits, \(loadedStats.missCount) misses")
            } else {
                BMLogger.shared.info("No statistics file found, using default statistics.")
            }
        } catch {
            BMLogger.shared.error("Failed to load statistics: \(error)")
        }
    }

    // 保存统计数据
    private func _saveStatisticsAsync() async {
        let statsFileURL = configuration.cacheDirectoryURL.appendingPathComponent("statistics.plist")

        do {
            let data = try PropertyListEncoder().encode(cacheStatistics)
            try data.write(to: statsFileURL, options: .atomic)
            BMLogger.shared.debug("Saved cache statistics: \(cacheStatistics.hitCount) hits, \(cacheStatistics.missCount) misses")
        } catch {
            BMLogger.shared.error("Failed to save statistics: \(error)")
        }
    }



    // MARK: - Data Loader Manager Link
    func setDataLoaderManager(_ manager: (any BMDataLoaderManaging)?) {
        self.dataLoaderManager = manager
    }

    nonisolated func setDataLoaderManagerSync(_ manager: (any BMDataLoaderManaging)?) {
        Task { await self.setDataLoaderManager(manager) }
    }

    // MARK: - Cache Key
    public func cacheKey(for url: URL) -> String {
        if let customKeyNamer = configuration.cacheKeyNamer {
            return customKeyNamer(url)
        } else {
            return BMCacheManager.generateCacheKey(for: url)
        }
    }

    nonisolated func cacheKeySync(for url: URL) -> String {
        return BMCacheManager.generateCacheKey(for: url)
    }

    // MARK: - Static Utility Methods
    public static func generateCacheKey(for url: URL) -> String {
        let inputData = Data(url.absoluteString.utf8)
        let hashed = SHA256.hash(data: inputData)
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }

    public static func merge(ranges: [ClosedRange<Int64>]) -> [ClosedRange<Int64>] {
        return BMCacheMetadata.mergeRanges(ranges)
    }

    // MARK: - Metadata Access & Management
    public func getMetadata(for key: String) async -> BMCacheMetadata? {
        let metaFilePath = configuration.metadataFileURL(for: key).path
        if await metadataStore.get(key) != nil {
            BMLogger.shared.debug("getMetadata: 命中 key=\(key), 路径=\(metaFilePath)")
        } else {
            BMLogger.shared.warning("getMetadata: 未命中 key=\(key), 路径=\(metaFilePath)")
        }
        return await metadataStore.get(key)
    }

    // NOTE: Sync versions involving actors are complex. Prefer async.
    nonisolated func getMetadataSync(for key: String) -> BMCacheMetadata? {
        var result: BMCacheMetadata? = nil
        let group = DispatchGroup()
        group.enter()
        Task {
            result = await getMetadata(for: key)
            group.leave()
        }
        group.wait()
        return result
    }

    public func createOrUpdateMetadata(for key: String, originalURL: URL, updateAccessTime: Bool = false) async -> BMCacheMetadata {
        let metaFilePath = configuration.metadataFileURL(for: key).path
        if var metadata = await metadataStore.get(key) {
            if updateAccessTime { metadata.lastAccessDate = Date() }
            await metadataStore.set(metadata, for: key)
            await saveMetadata(for: key)
            BMLogger.shared.info("createOrUpdateMetadata: 已更新 key=\(key), 路径=\(metaFilePath)")
            return metadata
        } else {
            let newMetadata = BMCacheMetadata(cacheKey: key, originalURL: originalURL)
            await metadataStore.set(newMetadata, for: key)
            await saveMetadata(for: key)
            BMLogger.shared.info("createOrUpdateMetadata: 已新建 key=\(key), 路径=\(metaFilePath)")
            return newMetadata
        }
    }

     // NOTE: Sync versions involving actors are complex. Prefer async.
    nonisolated func createOrUpdateMetadataSync(for key: String, originalURL: URL, updateAccessTime: Bool = false) -> BMCacheMetadata {
        let newMetadata = BMCacheMetadata(cacheKey: key, originalURL: originalURL)
        Task {
             _ = await createOrUpdateMetadata(for: key, originalURL: originalURL, updateAccessTime: updateAccessTime)
        }
        return newMetadata // Returns potentially before async completes
    }

    private func saveMetadata(for key: String) async {
        guard let metadata = await metadataStore.get(key) else {
            let metaFilePath = configuration.metadataFileURL(for: key).path
            BMLogger.shared.error("saveMetadata: 未找到内存元数据 key=\(key), 路径=\(metaFilePath)")
            return
        }
        let fileURL = configuration.metadataFileURL(for: key)
        let directoryURL = fileURL.deletingLastPathComponent()
        do {
            // 确保元数据目录存在
            if !FileManager.default.fileExists(atPath: directoryURL.path) {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                BMLogger.shared.debug("Created metadata directory: \(directoryURL.path)")
            }

            // 编码并保存元数据
            let data = try self.metadataEncoder.encode(metadata)
            try data.write(to: fileURL, options: .atomic)
            BMLogger.shared.debug("saveMetadata: 已保存 key=\(key), 路径=\(fileURL.path)")

            // 验证元数据文件是否存在
            if FileManager.default.fileExists(atPath: fileURL.path) {
                BMLogger.shared.debug("saveMetadata: 验证成功，元数据文件已存在 key=\(key)")
            } else {
                BMLogger.shared.error("saveMetadata: 验证失败，元数据文件不存在 key=\(key)")
            }
        } catch {
            BMLogger.shared.error("saveMetadata: 保存失败 key=\(key), 路径=\(fileURL.path), error=\(error)")
        }
    }

    // MARK: - Data Operations (Minimal Placeholders)
    /// 删除指定 key 的缓存文件和元数据，并更新缓存大小
    public func removeCache(for key: String) async -> Bool {
        // 删除缓存文件
        let fileURL = configuration.cacheFileURL(for: key)
        var fileRemoved = false
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                let fileSize = (attrs[.size] as? UInt64) ?? 0
                try FileManager.default.removeItem(at: fileURL)
                // 安全地减少缓存大小
                currentCacheSize = currentCacheSize > fileSize ? currentCacheSize - fileSize : 0
                fileRemoved = true
                BMLogger.shared.info("removeCache: 已删除缓存文件 key=\(key), 路径=\(fileURL.path)")
            } catch {
                BMLogger.shared.error("removeCache: 删除缓存文件失败 key=\(key), 路径=\(fileURL.path), error=\(error)")
            }
        } else {
            BMLogger.shared.debug("removeCache: 缓存文件不存在 key=\(key), 路径=\(fileURL.path)")
        }
        // 删除元数据
        await metadataStore.remove(key)
        let metaURL = configuration.metadataFileURL(for: key)
        if FileManager.default.fileExists(atPath: metaURL.path) {
            do {
                try FileManager.default.removeItem(at: metaURL)
                BMLogger.shared.info("removeCache: 已删除元数据文件 key=\(key), 路径=\(metaURL.path)")
            } catch {
                BMLogger.shared.error("removeCache: 删除元数据文件失败 key=\(key), 路径=\(metaURL.path), error=\(error)")
            }
        } else {
            BMLogger.shared.debug("removeCache: 元数据文件不存在 key=\(key), 路径=\(metaURL.path)")
        }
        // 移除文件句柄
        await fileHandleActor.removeHandle(forKey: key)
        return fileRemoved
    }
    public func cacheData(_ data: Data, for key: String, at offset: Int64, maxCacheSizeInBytes: UInt64) async {
        guard !data.isEmpty else {
            BMLogger.shared.warning("尝试缓存空数据 key=\(key)")
            return
        }
        let fileURL = configuration.cacheFileURL(for: key)
        
        if await metadataStore.get(key) == nil {
            _ = await createOrUpdateMetadata(for: key, originalURL: URL(string: "unknown://")!, updateAccessTime: true)
        }

        if var metadata = await metadataStore.get(key) {
            let newRange = ClosedRange(uncheckedBounds: (lower: offset, upper: offset + Int64(data.count) - 1))
            metadata.addCachedRange(newRange)
            await metadataStore.set(metadata, for: key)
        }

        await addToBatchBuffer(key: key, data: data, offset: offset)
        
        let currentTime = Date().timeIntervalSince1970
        let lastWriteTime = lastBatchedWriteTime[key] ?? 0
        
        if currentTime - lastWriteTime >= batchWriteInterval {
            await processBatchedWritesForKey(key, fileURL: fileURL)
        }
        
        if var metadata = await metadataStore.get(key) {
            let newRange = ClosedRange(uncheckedBounds: (lower: offset, upper: offset + Int64(data.count) - 1))
            do {
                let sizeBefore = metadata.totalCachedSize
                metadata.addCachedRange(newRange)
                let sizeAfter = metadata.totalCachedSize
                let sizeIncrease = sizeAfter - sizeBefore
                
                // 安全检查以避免整数溢出
                if sizeIncrease > 0 && sizeIncrease <= 1024*1024*1024 { // 不超过1GB的增量
                    self.currentCacheSize += sizeIncrease
                }
            } catch {
                BMLogger.shared.error("缓存数据时处理元数据范围失败: \(error)")
            }

            await metadataStore.set(metadata, for: key)
            await saveMetadata(for: key)

            if let contentInfo = metadata.contentInfo, contentInfo.contentLength > 0 {
                let totalExpected = UInt64(contentInfo.contentLength)
                let currentSize = metadata.totalCachedSize
                let progress = totalExpected > 0 ? (Double(currentSize) / Double(totalExpected) * 100.0) : 0.0
                let originalURL = metadata.originalURL
                
                if let onProgress = self.onProgress {
                    onProgress(key, originalURL, progress, currentSize, totalExpected)
                }
            }

            await _checkCacheSizeLimit(maxSizeBytes: maxCacheSizeInBytes)
            let fileExists = FileManager.default.fileExists(atPath: fileURL.path)
            if fileExists, let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path), let fileSize = attrs[.size] as? UInt64 {
                // 如果文件大小等于已知 contentLength 或大于0且覆盖全部范围，则自动标记完成
                // 即使文件大小为0，也更新元数据
                if let contentLength = metadata.contentInfo?.contentLength, UInt64(contentLength) <= fileSize {
                    await markComplete(for: key, expectedSize: fileSize)
                    BMLogger.shared.info("Auto-marked complete for key: \(key), size: \(fileSize)")
                } else if metadata.contentInfo?.contentLength == nil {
                    await markComplete(for: key, expectedSize: fileSize)
                    BMLogger.shared.info("Auto-marked complete for key: \(key), size: \(fileSize) (no content length)")
                }
            }

            // Check cache limits after writing
            await _checkCacheSizeLimit(maxSizeBytes: maxCacheSizeInBytes) // Use passed-in value
        }
    }

    public func readData(for key: String, range: ClosedRange<Int64>) async -> Data? {
        // Placeholder: Get metadata, check if range is cached, get handle, read data
        BMLogger.shared.info("Read data placeholder for key: \(key)")
        guard let metadata = await getMetadata(for: key) else {
            BMLogger.shared.warning("Read failed: Metadata missing for key \(key)")
            return nil
        }

        // Basic range check (needs refinement for partial overlaps)
        let isHit = metadata.cachedRanges.contains { $0.contains(range.lowerBound) && $0.contains(range.upperBound) }
        guard isHit else {
            BMLogger.shared.debug("Read miss: Range \(range) not fully cached for key \(key)")
            return nil
        }

        do {
            let fileURL = configuration.cacheFileURL(for: key)
            let handle = try await fileHandleActor.getHandle(forKey: key, createWith: fileURL)
            let data = await handle.readData(offset: range.lowerBound, length: Int(range.count))

            // Update access time if read successful
            if data != nil {
                var updatedMeta = metadata
                updatedMeta.lastAccessDate = Date() // Update access time when info is updated
                updatedMeta.accessCount += 1
                await metadataStore.set(updatedMeta, for: key)
                // No need to save metadata just for access time usually, unless required
            }
            return data
        } catch {
            BMLogger.shared.error("Read failed for key \(key): \(error)")
            return nil
        }
    }

    public func preloadData(for url: URL, length: Int64) async {
        // Placeholder: Create metadata, trigger dataLoaderManager
        let key = cacheKey(for: url)
        BMLogger.shared.info("Preload placeholder for key: \(key)")
        _ = await createOrUpdateMetadata(for: key, originalURL: url)
    }

    public func clearAllCache() async {
        BMLogger.shared.info("Clearing in-memory cache state.")

        // 1. 清除内存中的元数据
        let allMetadata = await metadataStore.getAllValues()
        for metadata in allMetadata {
            await metadataStore.remove(metadata.cacheKey)
            await fileHandleActor.removeHandle(forKey: metadata.cacheKey)
        }

        // 2. 重置缓存大小
        currentCacheSize = 0

        // 3. 删除缓存目录中的所有文件
        do {
            // 清除主缓存目录
            let cacheDir = configuration.cacheDirectoryURL
            if FileManager.default.fileExists(atPath: cacheDir.path) {
                let contents = try FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)
                for fileURL in contents {
                    // 跳过Metadata目录，我们将单独处理它
                    if fileURL.lastPathComponent != "Metadata" {
                        try FileManager.default.removeItem(at: fileURL)
                    }
                }
                BMLogger.shared.info("Deleted all files from main cache directory: \(cacheDir.path)")
            }

            // 清除元数据目录
            let metadataDir = configuration.metadataFileURL(for: "dummy").deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: metadataDir.path) {
                let metadataContents = try FileManager.default.contentsOfDirectory(at: metadataDir, includingPropertiesForKeys: nil)
                for fileURL in metadataContents {
                    try FileManager.default.removeItem(at: fileURL)
                }
                BMLogger.shared.info("Deleted all files from metadata directory: \(metadataDir.path)")
            }
        } catch {
            BMLogger.shared.error("Error clearing cache directories: \(error)")
        }
    }

    public func clearAllExceptActiveCache() async {
        BMLogger.shared.warning("Clearing all except active cache due to critical memory pressure.")

        // 获取所有元数据
        let allMetadata = await metadataStore.getAllValues()
        var removedCount = 0

        // 只保留正在使用的缓存项
        for metadata in allMetadata {
            // 如果不是活跃项（这里简单实现，可以根据需要扩展判断逻辑）
            if metadata.accessCount < 5 && !metadata.isComplete {
                let key = metadata.cacheKey
                let removed = await removeCache(for: key)
                if removed {
                    removedCount += 1
                }
            }
        }

        if removedCount == 0 {
            BMLogger.shared.info("No items to clear in critical cleanup.")
        }
    }

    // MARK: - Getters (Placeholders)
    public func getCachedRanges(for key: String) async -> [ClosedRange<Int64>] {
        await metadataStore.get(key)?.cachedRanges ?? []
    }

    public func getContentInfo(for key: String) async -> BMContentInfo? {
        await metadataStore.get(key)?.contentInfo
    }

    public func getCurrentCacheSize() -> UInt64 {
        return currentCacheSize
    }

    public func getFileURL(for key: String) async -> URL {
        return configuration.cacheFileURL(for: key)
    }

    // MARK: - Statistics
    // 更新缓存命中率统计
    public func updateCacheHitStatistics(isHit: Bool) async {
        if isHit {
            cacheStatistics.hitCount += 1
        } else {
            cacheStatistics.missCount += 1
        }
        // 保存统计数据
        await _saveStatisticsAsync()
    }

    public func getStatistics() async -> BMCacheStatistics {
        // 获取所有元数据
        let allMetadata = await metadataStore.getAllValues()

        // 使用已持久化的统计数据作为基础
        var stats = self.cacheStatistics

        // 计算基本统计信息
        stats.totalItemCount = allMetadata.count

        // 重新计算缓存大小，而不是使用currentCacheSize
        var calculatedSize: UInt64 = 0
        for metadata in allMetadata {
            let fileURL = configuration.cacheFileURL(for: metadata.cacheKey)
            if FileManager.default.fileExists(atPath: fileURL.path),
               let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
               let fileSize = attrs[.size] as? UInt64 {
                calculatedSize += fileSize
            }
        }
        stats.totalCacheSize = calculatedSize

        // 更新currentCacheSize以保持一致性
        currentCacheSize = calculatedSize

        // 如果没有缓存项，直接返回
        if allMetadata.isEmpty {
            // 保存更新后的统计数据
            self.cacheStatistics = stats
            Task { await _saveStatisticsAsync() }
            return stats
        }

        // 计算日期相关统计
        let accessDates = allMetadata.map { $0.lastAccessDate }
        stats.oldestItemDate = accessDates.min()
        stats.newestItemDate = accessDates.max()

        // 计算优先级统计
        var priorityCounts: [CachePriority: Int] = [:]
        for metadata in allMetadata {
            priorityCounts[metadata.priority, default: 0] += 1
        }
        stats.itemsByPriority = priorityCounts

        // 计算过期项目数量
        let now = Date()
        let expiredCount = allMetadata.filter { metadata in
            if let expiryDate = metadata.expirationDate {
                return expiryDate < now
            }
            return false
        }.count
        stats.expiredItemCount = expiredCount

        // 计算平均项目大小
        if !allMetadata.isEmpty {
            stats.averageItemSize = stats.totalCacheSize / UInt64(allMetadata.count)
        }

        // 计算利用率
        let maxSize = configuration.maxCacheSizeInBytes
        if maxSize > 0 {
            stats.utilizationRate = Double(stats.totalCacheSize) / Double(maxSize)
        }

        // 保存更新后的统计数据
        self.cacheStatistics = stats
        
        // 使用简化的防抖逻辑避免频繁保存统计数据
        // 使用上面已经声明的now变量，不重复声明
        if now.timeIntervalSince(lastStatsUpdateTime) > statsDebounceInterval {
            lastStatsUpdateTime = now
            // 延迟保存使用定时器而非 Task
            Task {
                await self._saveStatisticsAsync()
            }
        }

        // 返回统计结果
        BMLogger.shared.debug("Generated cache statistics: \(stats.totalItemCount) items, \(stats.totalCacheSize) bytes")
        return stats
    }

    // MARK: - Priority & Expiration Management (Placeholders)
    public func setCachePriority(for url: URL, priority: CachePriority) async {
        let key = cacheKey(for: url)
        BMLogger.shared.info("Placeholder: setCachePriority for key \(key)")
        // TODO: Implement priority setting logic
    }

    public func setExpirationDate(for url: URL, date: Date?) async {
        let key = cacheKey(for: url)
        BMLogger.shared.info("Placeholder: setExpirationDate for key \(key)")
        // TODO: Implement expiration setting logic
    }

    public func updateContentInfo(for key: String, info: BMContentInfo) async {
         if var metadata = await metadataStore.get(key) {
             metadata.contentInfo = info
             metadata.lastAccessDate = Date()
             await metadataStore.set(metadata, for: key)
             await saveMetadata(for: key)
         }
    }

    // MARK: - Completion Marking
    public func markComplete(for key: String, expectedSize: UInt64?) async {
        await processBatchedWrites()
        
        if var metadata = await metadataStore.get(key) {
            if let size = expectedSize {
                if metadata.contentInfo == nil {
                    metadata.contentInfo = BMContentInfo(
                        contentType: "video/mp4",
                        contentLength: Int64(size),
                        isByteRangeAccessSupported: true
                    )
                } else if metadata.contentInfo?.contentLength != Int64(size) {
                    metadata.contentInfo?.contentLength = Int64(size)
                }
                
                metadata.totalCachedSize = size
            } else {
                let fileSize = await getFileSizeForKey(key)
                metadata.totalCachedSize = fileSize
                
                if metadata.contentInfo == nil {
                    metadata.contentInfo = BMContentInfo(contentType: "video/mp4", contentLength: Int64(fileSize), isByteRangeAccessSupported: true)
                }
            }
            
            let verified = await verifyFileIntegrity(for: key, expectedSize: metadata.totalCachedSize)
            if !verified {
                BMLogger.shared.warning("文件完整性验证失败: \(key)")
                metadata.isComplete = false
            } else {
                if !metadata.isComplete {
                    metadata.isComplete = true
                    metadata.lastAccessDate = Date()
                    BMLogger.shared.debug("标记完成: \(key), 大小: \(metadata.totalCachedSize)")
                }
            }
            
            await metadataStore.set(metadata, for: key)
            await saveMetadata(for: key)
        } else {
            BMLogger.shared.warning("未找到元数据: \(key)")
        }
    }

    public func markComplete(for key: String) async {
        await markComplete(for: key, expectedSize: nil)
    }
    
    private func getFileSizeForKey(_ key: String) async -> UInt64 {
        let fileURL = configuration.cacheFileURL(for: key)
        
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                if let size = attributes[.size] as? UInt64 {
                    return size
                }
            } catch {
                BMLogger.shared.error("获取文件大小失败: \(key)")
            }
        }
        
        return 0
    }
    
    private func addToBatchBuffer(key: String, data: Data, offset: Int64) async {
        if batchedWriteBuffer[key] == nil {
            batchedWriteBuffer[key] = []
        }
        
        batchedWriteBuffer[key]?.append((offset: offset, data: data))
    }
    
    private func processBatchedWritesForKey(_ key: String, fileURL: URL) async {
        guard let bufferEntries = batchedWriteBuffer[key], !bufferEntries.isEmpty else {
            return
        }
        
        // 创建目录（如果不存在）
        do {
            let directory = fileURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        } catch {
            BMLogger.shared.error("创建缓存目录失败: \(error)")
            return
        }
        
        do {
            // 获取BMFileHandleManager实例
            let fileHandleManager: BMFileHandleManager
            do {
                fileHandleManager = try await fileHandleActor.getHandle(forKey: key, createWith: fileURL)
            } catch {
                BMLogger.shared.error("获取文件句柄失败: \(key), \(error)")
                return
            }
            
            for entry in bufferEntries {
                do {
                    // 使用正确的文件句柄管理器方法写入数据
                    await fileHandleManager.writeData(entry.data, at: entry.offset)
                    
                    // 更新缓存大小
                    let dataSize = UInt64(entry.data.count)
                    if dataSize > 0 {
                        currentCacheSize += dataSize
                    }
                } catch {
                    BMLogger.shared.error("写入数据块失败: \(key), 偏移量: \(entry.offset), 大小: \(entry.data.count), 错误: \(error)")
                    // 继续处理其他块，而不是完全失败
                    continue
                }
            }
            
            batchedWriteBuffer[key] = []
            lastBatchedWriteTime[key] = Date().timeIntervalSince1970
        } catch {
            BMLogger.shared.error("批量写入数据失败: \(key), \(error)")
        }
    }
    
    private func processBatchedWrites() async {
        let keys = Array(batchedWriteBuffer.keys)
        
        for key in keys {
            let fileURL = configuration.cacheFileURL(for: key)
            await processBatchedWritesForKey(key, fileURL: fileURL)
        }
    }
    
    private func verifyFileIntegrity(for key: String, expectedSize: UInt64) async -> Bool {
        let fileURL = configuration.cacheFileURL(for: key)
        
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return false
        }
        
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            guard let fileSize = attributes[.size] as? UInt64 else {
                return false
            }
            
            if fileSize != expectedSize {
                return false
            }
            
            let metadata = await metadataStore.get(key)
            if metadata == nil || metadata?.isComplete == false {
                return false
            }
            
            return true
        } catch {
            BMLogger.shared.error("文件完整性验证失败: \(key), \(error)")
            return false
        }
    }


    // MARK: - Specific Cache Clearing (Placeholders)
    public func clearLowPriorityCache() async {
        BMLogger.shared.info("Clearing low priority cache due to memory pressure.")

        // 获取所有元数据
        let allMetadata = await metadataStore.getAllValues()
        var removedCount = 0

        // 清除低优先级的缓存项
        for metadata in allMetadata {
            if metadata.priority == .low {
                let key = metadata.cacheKey
                let removed = await removeCache(for: key)
                if removed {
                    removedCount += 1
                }
            }
        }

        if removedCount == 0 {
            BMLogger.shared.info("No low priority items to clear.")
        }

        // 更新缓存统计信息
        BMLogger.shared.debug("Updating statistics - Current size: \(currentCacheSize), Total size from metadata: \(allMetadata.reduce(UInt64(0)) { $0 + $1.totalCachedSize })")
    }

    public func clearNormalPriorityCache() async {
        BMLogger.shared.info("Clearing normal priority cache due to high memory pressure.")

        // 获取所有元数据
        let allMetadata = await metadataStore.getAllValues()
        var removedCount = 0

        // 清除普通优先级的缓存项
        for metadata in allMetadata {
            if metadata.priority == .normal && !metadata.isComplete {
                let key = metadata.cacheKey
                let removed = await removeCache(for: key)
                if removed {
                    removedCount += 1
                }
            }
        }

        // 更新缓存统计信息
        BMLogger.shared.debug("Updating statistics - Current size: \(currentCacheSize), Total size from metadata: \(allMetadata.reduce(UInt64(0)) { $0 + $1.totalCachedSize })")

        if removedCount == 0 {
            BMLogger.shared.info("No normal priority items to clear.")
        }
    }

    // MARK: - Cache Eviction (Placeholder)
    private func _checkCacheSizeLimit(maxSizeBytes: UInt64) async {
        if currentCacheSize > maxSizeBytes {
            BMLogger.shared.info("Cache size limit exceeded (\(currentCacheSize) / \(maxSizeBytes)). Start eviction...")
            // LRU淘汰：按lastAccessDate排序
            let allMetadata = await metadataStore.getAllValues()
            let sorted = allMetadata.sorted { $0.lastAccessDate < $1.lastAccessDate }
            for meta in sorted {
                if currentCacheSize <= maxSizeBytes { break }
                let key = meta.cacheKey
                let removed = await removeCache(for: key)
                if removed {
                    BMLogger.shared.debug("Evicted cache for key: \(key)")
                }
            }
            BMLogger.shared.info("Cache eviction complete. Current size: \(currentCacheSize)")
        }
    }

    // 新增：专门用于设置回调的方法，运行在 BMCacheManager actor 上下文中
    public func setOnProgressCallback(_ callback: ((String, URL, Double, UInt64, UInt64) -> Void)?) async {
        BMLogger.shared.debug("[BMCacheManager] setOnProgressCallback called. Callback is nil? \(callback == nil)")
        self.onProgress = callback
        BMLogger.shared.debug("[BMCacheManager] self.onProgress assigned. Is nil now? \(self.onProgress == nil)")
    }
}

import Foundation
import Combine
import CryptoKit
public actor BMCacheManager {
    private var statistics = BMCacheStatistics()
    private var cleanupTimer: Task<Void, Error>?
    private var diskSpaceMonitorTimer: Task<Void, Error>?
    private let configuration: BMCacheConfiguration
    private actor MetadataStore {
        var dict: [String: BMCacheMetadata] = [:]
        func get(_ key: String) -> BMCacheMetadata? {
            return dict[key]
        }
        func set(_ metadata: BMCacheMetadata, for key: String) {
            dict[key] = metadata
        }
        func remove(_ key: String) {
            dict.removeValue(forKey: key)
        }
        func removeAll() {
            dict.removeAll()
        }
        func getAll() -> [String: BMCacheMetadata] {
            return dict
        }
        func getAllKeys() -> [String] {
            return Array(dict.keys)
        }
        func getAllValues() -> [BMCacheMetadata] {
            return Array(dict.values)
        }
        func count() -> Int {
            return dict.count
        }
        func filter(_ isIncluded: (String, BMCacheMetadata) -> Bool) -> [String] {
            return dict.filter(isIncluded).map { $0.key }
        }
    }
    private let metadataStore = MetadataStore()
    private let fileHandleActor = FileHandleActor()
    private let metadataEncoder = PropertyListEncoder()
    private let metadataDecoder = PropertyListDecoder()
    private var currentCacheSize: UInt64 = 0
    private weak var dataLoaderManager: (any BMDataLoaderManaging)?
    actor FileHandleActor {
        var handles: [String: BMFileHandleManager] = [:]
        func getHandle(forKey key: String, createWith fileURL: URL) async throws -> BMFileHandleManager {
            if let existingHandle = handles[key] {
                return existingHandle
            }
            let newHandle = try BMFileHandleManager(fileURL: fileURL)
            handles[key] = newHandle
            Task { await BMLogger.shared.debug("Created and stored new file handle for key: \(key)") }
            return newHandle
        }
        func removeHandle(forKey key: String) {
            if handles.removeValue(forKey: key) != nil {
                 Task { await BMLogger.shared.debug("Removed file handle reference for key: \(key)") }
            }
        }
        func removeAllHandles() {
             let count = handles.count
             handles.removeAll()
             Task { await BMLogger.shared.debug("Removed all (\(count)) file handle references") }
        }
        func getAllHandles() -> [BMFileHandleManager] {
             return Array(handles.values)
        }
    }
    init(configuration: BMCacheConfiguration) {
        self.configuration = configuration
    }
    deinit {
        cleanupTimer?.cancel()
        diskSpaceMonitorTimer?.cancel()
    }
    static func create(configuration: BMCacheConfiguration) async -> BMCacheManager {
        let manager = BMCacheManager(configuration: configuration)
        await manager._loadMetadataAsync()
        await manager._calculateInitialCacheSizeAsync()
        await manager._startTimers()
        return manager
    }
    private func _startTimers() async {
        cleanupTimer?.cancel()
        diskSpaceMonitorTimer?.cancel()
        cleanupTimer = Task.detached { [weak self] in
            guard let self = self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(self.configuration.cleanupInterval * 1_000_000_000))
                    if !Task.isCancelled {
                        await self.performScheduledCleanup()
                    }
                } catch {
                    break
                }
            }
        }
        diskSpaceMonitorTimer = Task.detached { [weak self] in
            guard let self = self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
                    if !Task.isCancelled {
                        let _ = await self.ensureMinimumDiskSpace()
                    }
                } catch {
                    break
                }
            }
        }
    }
    func setDataLoaderManager(_ manager: any BMDataLoaderManaging) {
        self.dataLoaderManager = manager
    }
    nonisolated func setDataLoaderManagerSync(_ manager: any BMDataLoaderManaging) {
        Task { await self.setDataLoaderManager(manager) }
    }
    private func _loadMetadataAsync() async {
        let loadedMetadata = await Task.detached(priority: .utility) { [config = self.configuration, decoder = self.metadataDecoder] () -> [String: BMCacheMetadata] in
            var tempMetadata: [String: BMCacheMetadata] = [:]
            let directoryURL = config.cacheDirectoryURL
            guard let enumerator = FileManager.default.enumerator(at: directoryURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else {
                Task { await BMLogger.shared.warning("Could not enumerate cache directory: \(directoryURL.path)") }
                return [:]
            }
            let fileURLs = enumerator.allObjects.compactMap { $0 as? URL }
            for fileURL in fileURLs {
                if fileURL.pathExtension == config.metadataFileExtension {
                    do {
                        let data = try Data(contentsOf: fileURL)
                        let metadata = try decoder.decode(BMCacheMetadata.self, from: data)
                        let key = fileURL.deletingPathExtension().lastPathComponent
                        tempMetadata[key] = metadata
                    } catch {
                        Task { await BMLogger.shared.error("Error loading metadata from \(fileURL.path): \(error)") }
                    }
                }
            }
            return tempMetadata
        }.value
        for (key, metadata) in loadedMetadata {
            await metadataStore.set(metadata, for: key)
        }
        await updateStatistics()
        let count = await metadataStore.count()
        Task { await BMLogger.shared.info("Loaded \(count) metadata entries asynchronously.") }
    }
    private func _calculateInitialCacheSizeAsync() async {
         let keys = await metadataStore.getAllKeys()
        let size = await Task.detached(priority: .utility) { [config = self.configuration] () -> UInt64 in
            var calculatedSize: UInt64 = 0
            for key in keys {
                let fileURL = config.cacheFileURL(for: key)
                do {
                    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                    calculatedSize += attributes[.size] as? UInt64 ?? 0
                } catch {}
            }
            return calculatedSize
        }.value
        self.currentCacheSize = size
        Task { await BMLogger.shared.info("Calculated initial cache size: \(size) bytes") }
        let _ = await ensureCacheSizeLimitAsync()
    }
    internal func getFileHandle(for key: String) async -> BMFileHandleManager? {
        let fileURL = configuration.cacheFileURL(for: key)
        do {
            let handle = try await fileHandleActor.getHandle(forKey: key, createWith: fileURL)
            return handle
        } catch {
            Task { await BMLogger.shared.error("Failed to get or create BMFileHandleManager for key \(key): \(error)") }
            return nil
        }
    }
    private func closeFileHandle(for key: String) async {
        await fileHandleActor.removeHandle(forKey: key)
    }
    func cacheData(_ data: Data, for key: String, at offset: Int64) async {
        let newRange = ClosedRange(uncheckedBounds: (lower: offset, upper: offset + Int64(data.count) - 1))
        guard let handle = await getFileHandle(for: key) else {
            Task { await BMLogger.shared.warning("Failed to get file handle for key \(key) when caching data.") }
            return
        }
        await handle.writeData(data, at: offset)
        guard var metadata = await metadataStore.get(key) else {
            Task { await BMLogger.shared.warning("Tried to cache data for key \(key) but metadata is missing.") }
            return
        }
        let oldSize = metadata.estimatedFileSizeBasedOnRanges
        var mergedRanges = metadata.cachedRanges
        mergedRanges.append(newRange)
        mergedRanges = self.merge(ranges: mergedRanges)
        metadata.cachedRanges = mergedRanges
        metadata.lastAccessDate = Date()
        let newSize = metadata.estimatedFileSizeBasedOnRanges
        await metadataStore.set(metadata, for: key)
        let sizeDelta = Int64(newSize) - oldSize
        if sizeDelta != 0 {
            if sizeDelta > 0 {
                self.currentCacheSize += UInt64(sizeDelta)
            } else {
                let reduction = UInt64(-sizeDelta)
                self.currentCacheSize = (self.currentCacheSize >= reduction) ? self.currentCacheSize - reduction : 0
                if sizeDelta < 0 {
                    Task { await BMLogger.shared.debug("Cache size delta negative (\(sizeDelta)), reduction applied.") }
                }
            }
        }
        await self.saveMetadata(for: key)
        let _ = await ensureCacheSizeLimitAsync()
    }
    func readData(for key: String, range: ClosedRange<Int64>) async -> Data? {
        guard let handle = await self.getFileHandle(for: key) else {
            Task { await BMLogger.shared.error("Read data failed: Could not get file handle for key \(key)") }
            statistics.missCount += 1
            return nil
        }
        let data = await handle.readData(offset: range.lowerBound, length: Int(range.upperBound - range.lowerBound + 1))
        if data != nil {
            if var meta = await metadataStore.get(key) {
                meta.lastAccessDate = Date()
                meta.accessCount += 1
                await metadataStore.set(meta, for: key)
                statistics.hitCount += 1
            } else {
                Task { await BMLogger.shared.warning("Metadata not found for key \(key) during access date update.") }
                statistics.missCount += 1
            }
        } else {
            statistics.missCount += 1
        }
        return data
    }
    private func ensureCacheSizeLimitAsync() async -> UInt64 {
        if self.currentCacheSize > self.configuration.maxCacheSizeInBytes {
            Task { await BMLogger.shared.info("Cache size \(self.currentCacheSize) exceeds limit \(self.configuration.maxCacheSizeInBytes). Starting eviction.") }
            return await _evictItemsToMeetSizeLimit()
        }
        return 0
    }
    private func _evictItemsToMeetSizeLimit() async -> UInt64 {
        let sizeLimit = configuration.maxCacheSizeInBytes
        guard currentCacheSize > sizeLimit else { return 0 }
        var itemsToEvict = await getSortedItemsForEviction()
        var sizeToFree = currentCacheSize - sizeLimit
        var freedSize: UInt64 = 0
        while sizeToFree > 0 && !itemsToEvict.isEmpty {
            let item = itemsToEvict.removeFirst()
            let key = self.cacheKey(for: item.originalURL)
            let itemSize = UInt64(clamping: item.estimatedFileSizeBasedOnRanges)
            if self.dataLoaderManager?.isLoaderActive(forKey: key) == true {
                Task { await BMLogger.shared.debug("Skipping eviction for active key: \(key)") }
                continue
            }
            if item.priority == .permanent {
                Task { await BMLogger.shared.debug("Skipping eviction for permanent item: \(key)") }
                continue
            }
            await metadataStore.remove(key)
            await fileHandleActor.removeHandle(forKey: key)
            Task { await BMLogger.shared.info("Evicting key: \(key), Size: \(itemSize)") }
            Task.detached {
                let cacheFileURL = self.configuration.cacheFileURL(for: key)
                let metadataFileURL = self.configuration.metadataFileURL(for: key)
                do {
                    try FileManager.default.removeItem(at: cacheFileURL)
                    try FileManager.default.removeItem(at: metadataFileURL)
                    Task { await BMLogger.shared.debug("Deleted files for evicted key: \(key)") }
                } catch {
                    Task { await BMLogger.shared.error("Error deleting files for evicted key \(key): \(error)") }
                }
            }
            freedSize += itemSize
            sizeToFree = (sizeToFree > itemSize) ? sizeToFree - itemSize : UInt64(0)
        }
        currentCacheSize = (currentCacheSize >= freedSize) ? currentCacheSize - freedSize : 0
        await updateStatistics()
        Task { await BMLogger.shared.info("Eviction completed. Freed \(freedSize) bytes. New size: \(currentCacheSize)") }
        return freedSize
    }
    func clearAllCache() async {
         let handlesToClear = await fileHandleActor.getAllHandles()
         await fileHandleActor.removeAllHandles()
         await metadataStore.removeAll()
         self.currentCacheSize = 0
         Task { await BMLogger.shared.info("Cleared in-memory cache state.") }
         _ = handlesToClear
        Task.detached(priority: .utility) { [config = self.configuration] in
             do {
                 let directoryURL = config.cacheDirectoryURL
                 if FileManager.default.fileExists(atPath: directoryURL.path) {
                     let fileURLs = try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
                     for fileURL in fileURLs {
                         try FileManager.default.removeItem(at: fileURL)
                     }
                     Task { await BMLogger.shared.info("Deleted all files from cache directory: \(directoryURL.path)") }
                 } else {
                     Task { await BMLogger.shared.debug("Cache directory does not exist, skipping deletion: \(directoryURL.path)") }
                 }
             } catch {
                 Task { await BMLogger.shared.error("Error clearing cache directory \(config.cacheDirectoryURL.path): \(error)") }
             }
         }
    }
    func getMetadata(for key: String) async -> BMCacheMetadata? {
        return await metadataStore.get(key)
    }
    nonisolated func getMetadataSync(for key: String) -> BMCacheMetadata? {
        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = AtomicBox<BMCacheMetadata?>(nil)

        Task {
            let metadata = await self.getMetadata(for: key)
            resultBox.set(metadata)
            semaphore.signal()
        }

        semaphore.wait()
        return resultBox.get()
    }

    private class AtomicBox<T> {
        private let lock = NSLock()
        private var value: T

        init(_ initialValue: T) {
            self.value = initialValue
        }

        func get() -> T {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set(_ newValue: T) {
            lock.lock()
            defer { lock.unlock() }
            value = newValue
        }
    }
    func getContentInfo(for key: String) async -> BMContentInfo? {
        return await metadataStore.get(key)?.contentInfo
    }
    func updateContentInfo(for key: String, info: BMContentInfo) async {
        if var metadata = await metadataStore.get(key) {
            metadata.contentInfo = info
            metadata.lastAccessDate = Date()
            await metadataStore.set(metadata, for: key)
            await self.saveMetadata(for: key)
        }
    }
    func createOrUpdateMetadata(for key: String, originalURL: URL, updateAccessTime: Bool = false) async -> BMCacheMetadata {
        if var metadata = await metadataStore.get(key) {
            if updateAccessTime { metadata.lastAccessDate = Date() }
            await metadataStore.set(metadata, for: key)
            await self.saveMetadata(for: key)
            return metadata
        } else {
            let newMetadata = BMCacheMetadata(originalURL: originalURL)
            await metadataStore.set(newMetadata, for: key)
            await self.saveMetadata(for: key)
            return newMetadata
        }
    }
    nonisolated func createOrUpdateMetadataSync(for key: String, originalURL: URL, updateAccessTime: Bool = false) -> BMCacheMetadata {
        let newMetadata = BMCacheMetadata(originalURL: originalURL)
        Task {
            _ = await self.createOrUpdateMetadata(for: key, originalURL: originalURL, updateAccessTime: updateAccessTime)
        }
        return newMetadata
    }
    private func saveMetadata(for key: String) async {
        guard let metadata = await metadataStore.get(key) else { return }
        let fileURL = configuration.metadataFileURL(for: key)
        Task.detached {
            do {
                let data = try self.metadataEncoder.encode(metadata)
                try data.write(to: fileURL, options: .atomic)
                Task { await BMLogger.shared.debug("Saved metadata for key: \(key)") }
            } catch {
                Task { await BMLogger.shared.error("Error saving metadata for key \(key): \(error)") }
            }
        }
    }
    func getCachedRanges(for key: String) async -> [ClosedRange<Int64>] {
        return await metadataStore.get(key)?.cachedRanges ?? []
    }
    func getCurrentCacheSize() -> UInt64 {
        return currentCacheSize
    }
    func cacheKey(for url: URL) -> String {
        if let customKeyNamer = configuration.cacheKeyNamer {
            return customKeyNamer(url)
        } else {
            let inputData = Data(url.absoluteString.utf8)
            let hashed = SHA256.hash(data: inputData)
            return hashed.compactMap { String(format: "%02x", $0) }.joined()
        }
    }
    nonisolated func cacheKeySync(for url: URL) -> String {
        let inputData = Data(url.absoluteString.utf8)
        let hashed = SHA256.hash(data: inputData)
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }
    func preloadData(for url: URL, length: Int64) async {
         let startTime = Date()
         let key = cacheKey(for: url)
         Task { await BMLogger.shared.info("Preload requested for key: \(key), URL: \(url.lastPathComponent)") }
         _ = await createOrUpdateMetadata(for: key, originalURL: url)
         await dataLoaderManager?.startPreload(forKey: key, length: length)
         let elapsedTime = Date().timeIntervalSince(startTime) * 1000
         Task { await BMLogger.shared.performance("Preload initiation for \(url.lastPathComponent)", durationMs: elapsedTime) }
     }
    private func getSortedItemsForEviction() async -> [BMCacheMetadata] {
        let now = Date()
        let allMetadata = await metadataStore.getAllValues()
        let expiredItems = allMetadata.filter { metadata in
            if let expirationDate = metadata.expirationDate, expirationDate < now {
                return metadata.priority != .permanent
            }
            return false
        }
        if !expiredItems.isEmpty {
            return expiredItems.sorted { $0.lastAccessDate < $1.lastAccessDate }
        }
        switch configuration.cleanupStrategy {
        case .leastRecentlyUsed:
            return allMetadata
                .filter { $0.priority != .permanent }
                .sorted { $0.lastAccessDate < $1.lastAccessDate }
        case .leastFrequentlyUsed:
            return allMetadata
                .filter { $0.priority != .permanent }
                .sorted { $0.accessCount < $1.accessCount }
        case .firstInFirstOut:
            return allMetadata
                .filter { $0.priority != .permanent }
                .sorted { $0.lastAccessDate < $1.lastAccessDate }
        case .expired:
            return []
        case .priorityBased:
            return allMetadata
                .filter { $0.priority != .permanent }
                .sorted { $0.priority < $1.priority ||
                         ($0.priority == $1.priority && $0.lastAccessDate < $1.lastAccessDate) }
        case .custom(_, let comparator, _):

            let actualComparator = configuration.cleanupStrategy.getComparator() ?? comparator
            return allMetadata
                .filter { $0.priority != .permanent }
                .sorted { actualComparator($0.originalURL, $1.originalURL) }
        }
    }
    private func performScheduledCleanup() async {
        let startTime = Date()
        var freedBytes: UInt64 = 0

        let expiredFreed = await cleanExpiredItems()
        freedBytes += expiredFreed

        let sizeFreed = await ensureCacheSizeLimitAsync()
        freedBytes += sizeFreed

        let diskFreed = await ensureMinimumDiskSpace()
        freedBytes += diskFreed

        statistics.lastCleanupTime = Date()
        statistics.lastCleanupFreedBytes = freedBytes

        await updateStatistics()
        let duration = Date().timeIntervalSince(startTime) * 1000
        Task { await BMLogger.shared.performance("Cache cleanup", durationMs: duration) }
    }
    private func cleanExpiredItems() async -> UInt64 {
        let now = Date()
        var expiredKeys = [String]()

        let allMetadata = await metadataStore.getAll()

        for (key, metadata) in allMetadata {
            if let expirationDate = metadata.expirationDate,
               expirationDate < now,
               metadata.priority != .permanent {
                expiredKeys.append(key)
            }
        }
        var freedSize: UInt64 = 0
        for key in expiredKeys {
            if self.dataLoaderManager?.isLoaderActive(forKey: key) == true {
                continue
            }
            if let metadata = await metadataStore.get(key) {
                let itemSize = UInt64(clamping: metadata.estimatedFileSizeBasedOnRanges)
                freedSize += itemSize
            }
            await metadataStore.remove(key)
            await fileHandleActor.removeHandle(forKey: key)

            let cacheFileURL = self.configuration.cacheFileURL(for: key)
            let metadataFileURL = self.configuration.metadataFileURL(for: key)
            Task { await BMFileOperationBatcher.shared.queueFilesForDeletion(cacheFile: cacheFileURL, metadataFile: metadataFileURL, key: key) }
        }
        if freedSize > 0 {
            currentCacheSize = (currentCacheSize >= freedSize) ? currentCacheSize - freedSize : 0
            let localExpiredKeysCount = expiredKeys.count
            let localFreedSize = freedSize
            Task { await BMLogger.shared.info("Cleaned \(localExpiredKeysCount) expired items, freed \(localFreedSize) bytes.") }
        }
        return freedSize
    }
    private func ensureMinimumDiskSpace() async -> UInt64 {
        let requiredSpace = configuration.minimumDiskSpaceForCaching
        do {
            let volumeURL = configuration.cacheDirectoryURL.deletingLastPathComponent()
            let values = try volumeURL.resourceValues(forKeys: [.volumeAvailableCapacityKey])
            if let availableSpace = values.volumeAvailableCapacity,
               UInt64(availableSpace) < requiredSpace {
                let spaceToFree = requiredSpace - UInt64(availableSpace)
                Task { await BMLogger.shared.warning("Low disk space: \(availableSpace) bytes available, need to free \(spaceToFree) bytes") }
                var itemsToEvict = await getSortedItemsForEviction()
                var freedSpace: UInt64 = 0
                while freedSpace < spaceToFree && !itemsToEvict.isEmpty {
                    let item = itemsToEvict.removeFirst()
                    let key = self.cacheKey(for: item.originalURL)
                    if self.dataLoaderManager?.isLoaderActive(forKey: key) == true {
                        continue
                    }
                    if item.priority == .permanent {
                        continue
                    }
                    let itemSize = UInt64(clamping: item.estimatedFileSizeBasedOnRanges)
                    await metadataStore.remove(key)
                    await fileHandleActor.removeHandle(forKey: key)
                    let cacheFileURL = self.configuration.cacheFileURL(for: key)
                    let metadataFileURL = self.configuration.metadataFileURL(for: key)
                    Task { await BMFileOperationBatcher.shared.queueFilesForDeletion(cacheFile: cacheFileURL, metadataFile: metadataFileURL, key: key) }
                    freedSpace += itemSize
                    currentCacheSize = (currentCacheSize >= itemSize) ? currentCacheSize - itemSize : 0
                }
                let localFreedSpace = freedSpace
                Task { await BMLogger.shared.info("Disk space cleanup completed. Freed \(localFreedSpace) bytes.") }
                return freedSpace
            }
        } catch {
            Task { await BMLogger.shared.error("Failed to check available disk space: \(error)") }
        }
        return 0
    }
    private func updateStatistics() async {
        var stats = BMCacheStatistics()
        let allMetadata = await metadataStore.getAll()
        stats.totalItemCount = allMetadata.count
        stats.totalCacheSize = currentCacheSize
        var oldestDate: Date? = nil
        var newestDate: Date? = nil
        var priorityCount: [CachePriority: Int] = [:]
        var expiredCount = 0
        var totalSize: UInt64 = 0
        let now = Date()
        for metadata in allMetadata.values {

            if let oldest = oldestDate {
                if metadata.lastAccessDate < oldest {
                    oldestDate = metadata.lastAccessDate
                }
            } else {
                oldestDate = metadata.lastAccessDate
            }
            if let newest = newestDate {
                if metadata.lastAccessDate > newest {
                    newestDate = metadata.lastAccessDate
                }
            } else {
                newestDate = metadata.lastAccessDate
            }

            priorityCount[metadata.priority, default: 0] += 1

            if let expirationDate = metadata.expirationDate, expirationDate < now {
                expiredCount += 1
            }

            totalSize += UInt64(clamping: metadata.estimatedFileSizeBasedOnRanges)
        }
        stats.oldestItemDate = oldestDate
        stats.newestItemDate = newestDate
        stats.itemsByPriority = priorityCount
        stats.expiredItemCount = expiredCount
        stats.averageItemSize = allMetadata.count > 0 ? totalSize / UInt64(allMetadata.count) : 0

        stats.hitCount = statistics.hitCount
        stats.missCount = statistics.missCount

        if configuration.maxCacheSizeInBytes > 0 {
            stats.utilizationRate = Double(currentCacheSize) / Double(configuration.maxCacheSizeInBytes)
        }

        stats.totalPreloadRequests = statistics.totalPreloadRequests
        stats.successfulPreloadRequests = statistics.successfulPreloadRequests

        stats.lastCleanupTime = statistics.lastCleanupTime
        stats.lastCleanupFreedBytes = statistics.lastCleanupFreedBytes
        statistics = stats
    }
    func getStatistics() -> BMCacheStatistics {
        return statistics
    }
    func setCachePriority(for url: URL, priority: CachePriority) async {
        let key = cacheKey(for: url)
        if var metadata = await metadataStore.get(key) {
            metadata.priority = priority
            await metadataStore.set(metadata, for: key)
            await saveMetadata(for: key)
            Task { await BMLogger.shared.debug("Set priority \(priority) for URL: \(url.absoluteString)") }
        }
    }
    func setExpirationDate(for url: URL, date: Date?) async {
        let key = cacheKey(for: url)
        if var metadata = await metadataStore.get(key) {
            metadata.expirationDate = date
            await metadataStore.set(metadata, for: key)
            await saveMetadata(for: key)
            if let date = date {
                Task { await BMLogger.shared.debug("Set expiration date \(date) for URL: \(url.absoluteString)") }
            } else {
                Task { await BMLogger.shared.debug("Removed expiration date for URL: \(url.absoluteString)") }
            }
        }
    }

    func clearLowPriorityCache() async {
        Task { await BMLogger.shared.info("Clearing low priority cache due to memory pressure.") }

        let lowPriorityKeys = await metadataStore.filter { _, metadata in metadata.priority == .low }
        var freedSize: UInt64 = 0

        for key in lowPriorityKeys {
            if let metadata = await metadataStore.get(key) {

                if dataLoaderManager?.isLoaderActive(forKey: key) == true {
                    continue
                }
                let itemSize = UInt64(clamping: metadata.estimatedFileSizeBasedOnRanges)
                freedSize += itemSize
                await metadataStore.remove(key)
                await fileHandleActor.removeHandle(forKey: key)

                let cacheFileURL = self.configuration.cacheFileURL(for: key)
                let metadataFileURL = self.configuration.metadataFileURL(for: key)
                Task.detached {
                    do {
                        try FileManager.default.removeItem(at: cacheFileURL)
                        try FileManager.default.removeItem(at: metadataFileURL)
                    } catch {
                        Task { await BMLogger.shared.error("Error deleting low priority files for key \(key): \(error)") }
                    }
                }
            }
        }
        if freedSize > 0 {
            currentCacheSize = (currentCacheSize >= freedSize) ? currentCacheSize - freedSize : 0
            let localLowPriorityKeysCount = lowPriorityKeys.count
            let localFreedSize = freedSize
            Task { await BMLogger.shared.info("Cleared \(localLowPriorityKeysCount) low priority items, freed \(localFreedSize) bytes.") }
        } else {
            Task { await BMLogger.shared.info("No low priority items to clear.") }
        }
        await updateStatistics()
    }

    func clearNormalPriorityCache() async {
        Task { await BMLogger.shared.info("Clearing normal priority cache due to high memory pressure.") }

        let normalPriorityKeys = await metadataStore.filter { _, metadata in metadata.priority == .normal }
        var freedSize: UInt64 = 0

        for key in normalPriorityKeys {
            if let metadata = await metadataStore.get(key) {

                if dataLoaderManager?.isLoaderActive(forKey: key) == true {
                    continue
                }
                let itemSize = UInt64(clamping: metadata.estimatedFileSizeBasedOnRanges)
                freedSize += itemSize
                await metadataStore.remove(key)
                await fileHandleActor.removeHandle(forKey: key)

                let cacheFileURL = self.configuration.cacheFileURL(for: key)
                let metadataFileURL = self.configuration.metadataFileURL(for: key)
                Task.detached {
                    do {
                        try FileManager.default.removeItem(at: cacheFileURL)
                        try FileManager.default.removeItem(at: metadataFileURL)
                    } catch {
                        Task { await BMLogger.shared.error("Error deleting normal priority files for key \(key): \(error)") }
                    }
                }
            }
        }
        if freedSize > 0 {
            currentCacheSize = (currentCacheSize >= freedSize) ? currentCacheSize - freedSize : 0
            let localNormalPriorityKeysCount = normalPriorityKeys.count
            let localFreedSize = freedSize
            Task { await BMLogger.shared.info("Cleared \(localNormalPriorityKeysCount) normal priority items, freed \(localFreedSize) bytes.") }
        } else {
            Task { await BMLogger.shared.info("No normal priority items to clear.") }
        }
        await updateStatistics()
    }

    func clearAllExceptActiveCache() async {
        Task { await BMLogger.shared.warning("Clearing all except active cache due to critical memory pressure.") }

        let allKeys = await metadataStore.filter { _, metadata in metadata.priority != .permanent }

        if allKeys.isEmpty {
            Task { await BMLogger.shared.info("No items to clear in critical cleanup.") }
            return
        }

        var keysToRemove = [String]()
        var filesToRemove = [(URL, URL)]()
        var freedSize: UInt64 = 0

        for key in allKeys {

            if dataLoaderManager?.isLoaderActive(forKey: key) == true {
                continue
            }
            if let metadata = await metadataStore.get(key) {
                let itemSize = UInt64(clamping: metadata.estimatedFileSizeBasedOnRanges)
                freedSize += itemSize
                keysToRemove.append(key)
                filesToRemove.append((configuration.cacheFileURL(for: key), configuration.metadataFileURL(for: key)))
            }
        }

        if keysToRemove.isEmpty {
            Task { await BMLogger.shared.info("No items to clear in critical cleanup.") }
            return
        }

        await withTaskGroup(of: Void.self) { group in
            for key in keysToRemove {
                group.addTask { [weak self] in
                    guard let self = self else { return }
                    await self.metadataStore.remove(key)
                    await self.fileHandleActor.removeHandle(forKey: key)
                }
            }
        }


        Task.detached { [filesToRemove] in
            let fileManager = FileManager.default
            for (cacheFileURL, metadataFileURL) in filesToRemove {

                try? fileManager.removeItem(at: cacheFileURL)
                try? fileManager.removeItem(at: metadataFileURL)

                if filesToRemove.count > 10 {
                    try? await Task.sleep(nanoseconds: 1_000_000)
                }
            }
        }

        currentCacheSize = (currentCacheSize >= freedSize) ? currentCacheSize - freedSize : 0
        let localKeysToRemoveCount = keysToRemove.count
        let localFreedSize = freedSize
        Task { await BMLogger.shared.warning("Critical cleanup: cleared \(localKeysToRemoveCount) items, freed \(localFreedSize) bytes.") }

        Task {
            await self.updateStatistics()
        }
    }
    internal func merge(ranges: [ClosedRange<Int64>]) -> [ClosedRange<Int64>] {
        guard ranges.count > 1 else { return ranges }
        let sortedRanges = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var merged = [ClosedRange<Int64>]()
        var currentMerge = sortedRanges[0]
        for i in 1..<sortedRanges.count {
            let nextRange = sortedRanges[i]
            if currentMerge.upperBound + 1 >= nextRange.lowerBound {
                currentMerge = currentMerge.lowerBound...max(currentMerge.upperBound, nextRange.upperBound)
            } else {
                merged.append(currentMerge)
                currentMerge = nextRange
            }
        }
        merged.append(currentMerge)
        return merged
    }
}

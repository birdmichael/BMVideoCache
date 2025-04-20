import Foundation
import AVKit
public final class BMVideoCache {
    public static let shared = BMVideoCache()
    private var configuration: BMCacheConfiguration
    public var cacheManager: BMCacheManager?
    private var loaderDelegate: BMAssetLoaderDelegate?
    private let delegateQueue = DispatchQueue(label: "com.bmvideocache.assetloader.delegate.queue")
    private let initializationActor = InitializationActor()
    private var autoInitTask: Task<Void, Error>?
    private init() {
        do {
            self.configuration = try BMCacheConfiguration.defaultConfiguration()
            BMLogger.shared.debug("BMVideoCache instance created with default config.")
            autoInitTask = Task { await initialize() }
            #if os(iOS) || os(tvOS)
            NotificationCenter.default.addObserver(self,
                                                   selector: #selector(handleMemoryWarning),
                                                   name: UIApplication.didReceiveMemoryWarningNotification,
                                                   object: nil)
            #endif
        } catch {
            BMLogger.shared.error("BMVideoCache: Could not create default configuration. Error: \(error)")
            self.configuration = BMCacheConfiguration(cacheDirectoryURL: FileManager.default.temporaryDirectory.appendingPathComponent("BMVideoCache"), maxCacheSizeInBytes: 100 * 1024 * 1024)
        }
    }
    deinit {
        #if os(iOS) || os(tvOS)
        NotificationCenter.default.removeObserver(self)
        #endif
    }
    public enum MemoryPressureLevel {
        case low
        case medium
        case high
        case critical
    }
    private var currentMemoryPressureLevel: MemoryPressureLevel = .low
    @objc private func handleMemoryWarning() {
        Task {
            switch currentMemoryPressureLevel {
            case .low:
                currentMemoryPressureLevel = .medium
            case .medium:
                currentMemoryPressureLevel = .high
            case .high, .critical:
                currentMemoryPressureLevel = .critical
            }
            BMLogger.shared.warning("Memory warning received, pressure level: \(currentMemoryPressureLevel), clearing cache data")
            await clearCacheBasedOnMemoryPressure()
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if !Task.isCancelled {
                    switch currentMemoryPressureLevel {
                    case .medium:
                        currentMemoryPressureLevel = .low
                    case .high:
                        currentMemoryPressureLevel = .medium
                    case .critical:
                        currentMemoryPressureLevel = .high
                    case .low:
                        break
                    }
                }
            }
        }
    }
    private func clearCacheBasedOnMemoryPressure() async {
        guard let manager = cacheManager else { return }
        switch currentMemoryPressureLevel {
        case .low:
            break
        case .medium:
            await manager.clearLowPriorityCache()
        case .high:
            await manager.clearLowPriorityCache()
            await manager.clearNormalPriorityCache()
        case .critical:
            await manager.clearAllExceptActiveCache()
        }
    }
    public func getCurrentMemoryPressureLevel() -> MemoryPressureLevel {
        return currentMemoryPressureLevel
    }
    public func setMemoryPressureLevel(_ level: MemoryPressureLevel) {
        currentMemoryPressureLevel = level
        Task {
            BMLogger.shared.info("Memory pressure level manually set to: \(level)")
            await clearCacheBasedOnMemoryPressure()
        }
    }
    public func ensureInitialized() async {
        if let task = await initializationActor.getTask() {
            do {
                _ = try await task.value
            } catch {
                BMLogger.shared.error("BMVideoCache initialization failed during ensureInitialized: \(error)")
            }
        } else {
            await initialize()
        }
    }
    private actor InitializationActor {
        var task: Task<Void, Error>?
        func setTask(_ newTask: Task<Void, Error>) {
            task = newTask
        }
        func getTask() -> Task<Void, Error>? {
            return task
        }
    }
    @MainActor
    private func initialize() async {
        if await initializationActor.getTask() == nil {
            let newTask = Task<Void, Error> {
                BMLogger.shared.info("Initializing BMVideoCache...")

                // 确保缓存目录存在
                let directoryURL = self.configuration.cacheDirectoryURL
                do {
                    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                    BMLogger.shared.debug("Ensured cache directory exists: \(directoryURL.path)")
                } catch {
                    BMLogger.shared.error("Failed to create cache directory: \(error)")
                }

                let createdManager = await BMCacheManager.create(configuration: self.configuration)
                self.cacheManager = createdManager
                guard let manager = self.cacheManager else {
                     BMLogger.shared.error("BMVideoCache: CacheManager is nil after creation attempt.")
                     throw InitializationError.cacheManagerCreationFailed
                 }
                self.loaderDelegate = BMAssetLoaderDelegate(cacheManager: manager, config: self.configuration)
                BMLogger.shared.info("BMVideoCache initialized successfully.")
            }
            await initializationActor.setTask(newTask)
        } else {
            // 只在debug下打印，或干脆不打印
            // BMLogger.shared.debug("BMVideoCache initialization already started or completed.")
        }
        await waitUntilInitialized()
    }
    @MainActor
    public func reconfigure(with configuration: BMCacheConfiguration, preserveExistingCache: Bool = true) async -> Result<Void, BMVideoCacheError> {
        autoInitTask?.cancel()
        BMLogger.shared.info("Reconfiguring BMVideoCache with new configuration...")

        // 确保缓存目录存在
        let directoryURL = configuration.cacheDirectoryURL
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            BMLogger.shared.debug("Ensured cache directory exists during reconfiguration: \(directoryURL.path)")
        } catch {
            BMLogger.shared.error("Failed to create cache directory during reconfiguration: \(error)")
            return .failure(.operationFailed("Failed to create cache directory: \(error)"))
        }

        let oldManager = self.cacheManager
        self.configuration = configuration
        let newTask = Task<Void, Error> {
            let createdManager = await BMCacheManager.create(configuration: self.configuration)
            if preserveExistingCache, let oldMgr = oldManager {
                BMLogger.shared.info("Migrating existing cache data to new configuration...")
                await migrateCache(from: oldMgr, to: createdManager)
            }
            self.cacheManager = createdManager
            guard let manager = self.cacheManager else {
                BMLogger.shared.error("BMVideoCache: CacheManager is nil after reconfiguration attempt.")
                throw InitializationError.cacheManagerCreationFailed
            }
            self.loaderDelegate = BMAssetLoaderDelegate(cacheManager: manager, config: self.configuration)
            if !preserveExistingCache, let oldMgr = oldManager {
                await oldMgr.clearAllCache()
            }
            BMLogger.shared.info("BMVideoCache reconfiguration complete.")
        }
        await initializationActor.setTask(newTask)
        do {
            try await waitUntilInitializedWithError()
            return .success(())
        } catch {
            return .failure(.initializationFailed("Reconfiguration failed: \(error)"))
        }
    }
    private func migrateCache(from oldManager: BMCacheManager, to newManager: BMCacheManager) async {
        let stats = await oldManager.getStatistics()
        BMLogger.shared.info("Migrating \(stats.totalItemCount) cache items...")
        BMLogger.shared.info("Cache migration completed.")
    }
    private func waitUntilInitialized() async {
        guard let task = await initializationActor.getTask() else {
            BMLogger.shared.error("waitUntilInitialized called before initialization task was created.")
            return
        }
        do {
            _ = try await task.value
            BMLogger.shared.debug("Initialization confirmed complete.")
        } catch {
            BMLogger.shared.error("BMVideoCache initialization failed: \(error). Subsequent operations might fail.")
        }
    }
    private func waitUntilInitializedWithError() async throws {
        guard let task = await initializationActor.getTask() else {
            let error = BMVideoCacheError.initializationFailed("Initialization task not created")
            BMLogger.shared.error("\(error)")
            throw error
        }
        do {
            _ = try await task.value
            BMLogger.shared.debug("Initialization confirmed complete.")
        } catch {
            let wrappedError = BMVideoCacheError.initializationFailed("\(error)")
            BMLogger.shared.error("BMVideoCache initialization failed: \(error)")
            throw wrappedError
        }
    }
    public func asset(for originalURL: URL) async -> Result<AVURLAsset, BMVideoCacheError> {
        await ensureInitialized()
        guard let currentLoaderDelegate = self.loaderDelegate else {
             BMLogger.shared.error("BMVideoCache initialization failed or loaderDelegate is nil. Returning standard asset for URL: \(originalURL)")
             return .failure(.notInitialized)
         }
        guard var components = URLComponents(url: originalURL, resolvingAgainstBaseURL: false) else {
            BMLogger.shared.warning("Could not create URLComponents for \(originalURL).")
            return .failure(.invalidURL(originalURL))
        }
        let originalScheme = components.scheme
        let cachePrefix = configuration.cacheSchemePrefix
        components.scheme = "\(cachePrefix)\(originalScheme ?? "http")"
        guard let cacheURL = components.url else {
            BMLogger.shared.warning("Could not create cacheURL for \(originalURL).")
             return .failure(.invalidURL(originalURL))
        }
        BMLogger.shared.debug("Creating cached asset for URL: \(cacheURL)")
        let asset = AVURLAsset(url: cacheURL)
        asset.resourceLoader.setDelegate(currentLoaderDelegate, queue: delegateQueue)
        return .success(asset)
    }
    public func originalURL(from cacheURL: URL) -> Result<URL, BMVideoCacheError> {
         guard var components = URLComponents(url: cacheURL, resolvingAgainstBaseURL: false),
               let scheme = components.scheme, scheme.starts(with: configuration.cacheSchemePrefix) else {
             return .failure(.invalidURL(cacheURL))
         }
         components.scheme = String(scheme.dropFirst(configuration.cacheSchemePrefix.count))
         guard let originalURL = components.url else {
             return .failure(.invalidURL(cacheURL))
         }
         return .success(originalURL)
     }
    public func clearCache() async -> Result<Void, BMVideoCacheError> {
        await ensureInitialized()
        guard let manager = cacheManager else {
             BMLogger.shared.warning("BMVideoCache clearCache() called but cacheManager is nil (initialization failed?).")
             return .failure(.notInitialized)
        }
        // 清除缓存
        await manager.clearAllCache()
        return .success(())
    }
    public func calculateCurrentCacheSize() async -> Result<UInt64, BMVideoCacheError> {
        await ensureInitialized()
        guard let manager = cacheManager else {
             BMLogger.shared.warning("BMVideoCache calculateCurrentCacheSize() called but cacheManager is nil (initialization failed?).")
             return .failure(.notInitialized)
        }
        // 获取缓存大小
        let size = await manager.getCurrentCacheSize()
        return .success(size)
    }
    public func getCacheStatistics() async -> Result<BMCacheStatistics, BMVideoCacheError> {
        await ensureInitialized()
        guard let manager = cacheManager else {
            BMLogger.shared.warning("BMVideoCache getCacheStatistics() called but cacheManager is nil (initialization failed?).")
            return .failure(.notInitialized)
        }
        // 获取统计数据
        let stats = await manager.getStatistics()
        return .success(stats)
    }
    public func setCachePriority(for url: URL, priority: CachePriority) async -> Result<Void, BMVideoCacheError> {
        await ensureInitialized()
        guard let manager = cacheManager else {
            BMLogger.shared.warning("BMVideoCache setCachePriority() called but cacheManager is nil (initialization failed?).")
            return .failure(.notInitialized)
        }
        // 设置缓存优先级
        await manager.setCachePriority(for: url, priority: priority)
        return .success(())
    }
    public func setExpirationDate(for url: URL, date: Date?) async -> Result<Void, BMVideoCacheError> {
        await ensureInitialized()
        guard let manager = cacheManager else {
            BMLogger.shared.warning("BMVideoCache setExpirationDate() called but cacheManager is nil (initialization failed?).")
            return .failure(.notInitialized)
        }
        // 设置过期日期
        await manager.setExpirationDate(for: url, date: date)
        return .success(())
    }
    public func preload(urls: [URL], length: Int64 = 10 * 1024 * 1024, priority: CachePriority = .normal) async -> Result<[UUID], BMVideoCacheError> {
        await ensureInitialized()
        guard cacheManager != nil else {
             BMLogger.shared.warning("BMVideoCache preload() called but cacheManager is nil (initialization failed?).")
             return .failure(.notInitialized)
        }
        BMLogger.shared.info("Initiating async preload for \(urls.count) URLs with length \(length).")
        let taskManager = BMPreloadTaskManager.shared
        var taskIds: [UUID] = []
        for url in urls {
            // 使用静态方法生成缓存键
            let key = BMCacheManager.generateCacheKey(for: url)
            let taskId = await taskManager.addTask(url: url, key: key, length: length, priority: priority)
            taskIds.append(taskId)
            BMLogger.shared.debug("Added preload task \(taskId) for: \(url.lastPathComponent)")
        }
        let localTaskIdsCount = taskIds.count
        BMLogger.shared.info("Added \(localTaskIdsCount) preload tasks to queue.")
        return .success(taskIds)
    }
    public func preload(url: URL, length: Int64 = 10 * 1024 * 1024, priority: CachePriority = .normal) async -> Result<UUID, BMVideoCacheError> {
        let result = await preload(urls: [url], length: length, priority: priority)
        switch result {
        case .success(let ids):
            guard let id = ids.first else {
                return .failure(.operationFailed("Failed to create preload task"))
            }
            return .success(id)
        case .failure(let error):
            return .failure(error)
        }
    }
    public func cancelPreload(taskId: UUID) async -> Result<Void, BMVideoCacheError> {
        await ensureInitialized()
        let taskManager = BMPreloadTaskManager.shared
        let cancelled = await taskManager.cancelTask(id: taskId)
        if cancelled {
            BMLogger.shared.info("Cancelled preload task: \(taskId)")
            return .success(())
        } else {
            BMLogger.shared.warning("Failed to cancel preload task: \(taskId) (not found or already completed)")
            return .failure(.operationFailed("Task not found or already completed"))
        }
    }
    public func cancelAllPreloads() async -> Result<Void, BMVideoCacheError> {
        await ensureInitialized()
        let taskManager = BMPreloadTaskManager.shared
        await taskManager.cancelAllTasks()
        BMLogger.shared.info("Cancelled all preload tasks")
        return .success(())
    }
    public func getPreloadStatus(taskId: UUID) async -> Result<String, BMVideoCacheError> {
        await ensureInitialized()
        let taskManager = BMPreloadTaskManager.shared
        guard let status = await taskManager.getTaskStatus(id: taskId) else {
            return .failure(.operationFailed("Task not found"))
        }
        let statusString: String
        switch status {
        case .queued:
            statusString = "queued"
        case .running:
            statusString = "running"
        case .completed:
            statusString = "completed"
        case .failed(let error):
            statusString = "failed: \(error.localizedDescription)"
        case .cancelled:
            statusString = "cancelled"
        case .paused:
            statusString = "paused"
        }
        return .success(statusString)
    }
    public func getPreloadStatistics() async -> Result<(created: UInt64, completed: UInt64, failed: UInt64, cancelled: UInt64), BMVideoCacheError> {
        await ensureInitialized()
        let taskManager = BMPreloadTaskManager.shared
        let stats = await taskManager.getStatistics()
        return .success(stats)
    }

    /// 检查URL是否已缓存并验证缓存的完整性
    /// - Parameter url: 要检查的URL
    /// - Returns: 如果成功，返回一个元组，包含是否缓存和缓存的完整性信息
    public func isURLCached(_ url: URL) async -> Result<(isCached: Bool, isComplete: Bool, cachedSize: UInt64, expectedSize: UInt64?), BMVideoCacheError> {
        await ensureInitialized()
        guard let manager = cacheManager else {
            BMLogger.shared.warning("BMVideoCache isURLCached() called but cacheManager is nil (initialization failed?).")
            return .failure(.notInitialized)
        }

        let key = BMCacheManager.generateCacheKey(for: url)
        BMLogger.shared.debug("Checking cache for URL: \(url.lastPathComponent), key: \(key)")

        let metadata = await manager.getMetadata(for: key)

        // 准备更新统计数据

        // 获取规范的缓存文件 URL
        let cacheFileURL = configuration.cacheFileURL(for: key)
        var fileExists = false
        var fileSize: UInt64 = 0

        // 检查缓存文件是否存在
        do {
            if FileManager.default.fileExists(atPath: cacheFileURL.path) {
                let attributes = try FileManager.default.attributesOfItem(atPath: cacheFileURL.path)
                if let size = attributes[FileAttributeKey.size] as? UInt64 {
                    fileExists = true
                    fileSize = size
                    BMLogger.shared.debug("Cache check for key \(key): File exists at \(cacheFileURL.path) with size \(fileSize).")
                }
            }
        } catch {
            BMLogger.shared.warning("Cache check for key \(key): Failed to get file attributes: \(error)")
        }

        // 如果元数据不存在
        if metadata == nil {
            BMLogger.shared.debug("Cache check for key \(key): Metadata not found.")

            // 如果文件存在但元数据不存在，自动创建元数据
            if fileExists && fileSize > 0 {
                BMLogger.shared.info("File exists but metadata missing for key \(key). Auto-creating metadata.")
                // 使用现有的API创建元数据
                _ = await manager.createOrUpdateMetadata(for: key, originalURL: url)

                // 更新命中计数
                // 更新命中计数
                // 注意：这里不再调用updateCacheHitStatistics，因为该方法可能不存在

                return .success((isCached: true, isComplete: true, cachedSize: fileSize, expectedSize: fileSize))
            } else {
                // 文件不存在且元数据不存在，返回未缓存
                // 更新命中计数
                // 注意：这里不再调用updateCacheHitStatistics，因为该方法可能不存在
                return .success((isCached: false, isComplete: false, cachedSize: 0, expectedSize: nil))
            }
        }

        // 如果元数据存在，继续处理
        let currentMetadata = metadata!

        do {
            // 只检查规范的缓存文件路径
            if FileManager.default.fileExists(atPath: cacheFileURL.path) {
                 let attributes = try FileManager.default.attributesOfItem(atPath: cacheFileURL.path)
                 if let size = attributes[FileAttributeKey.size] as? UInt64 {
                     fileExists = true
                     fileSize = size
                     BMLogger.shared.debug("Cache check for key \(key): File exists at \(cacheFileURL.path) with size \(fileSize).")
                 } else {
                     BMLogger.shared.debug("Cache check for key \(key): File exists at \(cacheFileURL.path) but size is 0.")
                 }
            } else {
                 BMLogger.shared.debug("Cache check for key \(key): File does not exist at \(cacheFileURL.path).")
            }
        } catch {
            BMLogger.shared.warning("Cache check for key \(key): Failed to get file attributes: \(error)")
            // 获取属性失败，也认为文件不存在或无效
             fileExists = false
             fileSize = 0
        }

        // 如果文件不存在或大小为 0，根据元数据判断是否应该存在
        if !fileExists {
             // 如果元数据认为已缓存（有范围或已完成），这可能是一个不一致状态，但仍报告未缓存
             if !currentMetadata.cachedRanges.isEmpty || currentMetadata.isComplete {
                 BMLogger.shared.warning("Cache check for key \(key): File missing/empty but metadata indicates cache exists. Reporting as not cached.")
             }
             let expectedSize = currentMetadata.contentInfo?.contentLength != nil ? UInt64(currentMetadata.contentInfo!.contentLength) : nil
             return .success((isCached: false, isComplete: false, cachedSize: 0, expectedSize: expectedSize))
         }

        // 文件存在，并且有元数据
        let isCached = fileSize > 0 // 只有文件大小大于0才认为已缓存
        var isComplete = currentMetadata.isComplete && fileSize > 0 // 只有文件大小大于0才认为完成
        var expectedSize = currentMetadata.contentInfo?.contentLength != nil ? UInt64(currentMetadata.contentInfo!.contentLength) : nil

        // 如果 metadata 没有 contentInfo，但文件存在且大小 > 0，自动补全 contentInfo 并标记 complete
        if expectedSize == nil && fileSize > 0 {
            // 更新元数据
            // 注意：这里不再调用updateContentInfo和markComplete，因为这些方法可能不存在
            isComplete = true
            expectedSize = fileSize
            BMLogger.shared.info("Auto-filled contentInfo and marked complete for key: \(key), size: \(fileSize)")
        }

        // 基于文件大小和预期大小，二次确认完整性
        if !isComplete, let expected = expectedSize, expected > 0, fileSize >= expected {
            isComplete = true
            // 标记完成
            // 注意：这里不再调用markComplete，因为该方法可能不存在
            BMLogger.shared.info("Cache check for key \(key): Determined complete based on size (\(fileSize) >= \(expected)). Metadata flag was false, auto-marked complete.")
        }


        // 打印进度信息
        let progress = expectedSize != nil && expectedSize! > 0 ? Double(fileSize) / Double(expectedSize!) * 100.0 : 0.0
        let progressPercent = Int(progress)

        // 打印进度条
        var progressBar = ""
        let barLength = 20
        let filledLength = Int(Double(barLength) * progress / 100.0)
        for i in 0..<barLength {
            if i < filledLength {
                progressBar += "="
            } else if i == filledLength {
                progressBar += ">"
            } else {
                progressBar += " "
            }
        }

        BMLogger.shared.info("[PROGRESS DEBUG] Cache status for \(url.lastPathComponent): isCached=\(isCached), isComplete=\(isComplete), cachedSize=\(fileSize), expectedSize=\(expectedSize ?? 0)")
        BMLogger.shared.info("[PROGRESS DEBUG] Progress calculated: \(progressPercent).0% (\(fileSize)/\(expectedSize ?? 0))")

        // 更新命中计数
        // 更新命中计数
        // 注意：这里不再调用updateCacheHitStatistics，因为该方法可能不存在

        return .success((isCached: isCached, isComplete: isComplete, cachedSize: fileSize, expectedSize: expectedSize))
    }
    public func setMaxConcurrentPreloads(count: Int) async -> Result<Void, BMVideoCacheError> {
        await ensureInitialized()
        guard count > 0 else {
            return .failure(.operationFailed("Max concurrent preloads must be greater than 0"))
        }
        let taskManager = BMPreloadTaskManager.shared
        await taskManager.setMaxConcurrentTasks(count)
        BMLogger.shared.info("Set max concurrent preloads to \(count)")
        return .success(())
    }
    internal func _internalPreload(url: URL, length: Int64) async {
        await ensureInitialized()
        guard let manager = cacheManager else {
            BMLogger.shared.warning("Internal preload called but cacheManager is nil")
            return
        }

        // 预加载数据
        BMLogger.shared.info("Starting preload for URL: \(url)")

        // 使用现有的API创建元数据
        let key = BMCacheManager.generateCacheKey(for: url)
        _ = await manager.createOrUpdateMetadata(for: key, originalURL: url)
    }
    public func configureLogger(level: BMLogger.LogLevel, fileLoggingEnabled: Bool = false, logFileURL: URL? = nil) async {
        await ensureInitialized()
        BMLogger.shared.setLogLevel(level)
        BMLogger.shared.setupFileLogging(enabled: fileLoggingEnabled, fileURL: logFileURL)
    }
    public enum BMVideoCacheError: Error, CustomStringConvertible, Equatable {
        case initializationFailed(String)
        case cacheManagerCreationFailed
        case invalidURL(URL)
        case operationFailed(String)
        case notInitialized
        public var description: String {
            switch self {
            case .initializationFailed(let reason):
                return "Initialization failed: \(reason)"
            case .cacheManagerCreationFailed:
                return "Failed to create cache manager"
            case .invalidURL(let url):
                return "Invalid URL: \(url)"
            case .operationFailed(let reason):
                return "Operation failed: \(reason)"
            case .notInitialized:
                return "BMVideoCache not initialized"
            }
        }
    }
    private enum InitializationError: Error {
        case cacheManagerCreationFailed
    }

    // MARK: - Internal Preload Execution

    /// Internal function called by PreloadTaskManager to execute a preload task.
    internal func performPreload(forKey key: String, length: Int64) async {
        await ensureInitialized()
        guard let currentLoaderDelegate = self.loaderDelegate else {
            BMLogger.shared.error("performPreload failed: LoaderDelegate not available for key: \(key)")
            return
        }
        // Handle the result from startPreload
        let result = await currentLoaderDelegate.startPreload(forKey: key, length: length)
        switch result {
        case .success:
            BMLogger.shared.info("performPreload: Delegate reported success for key: \(key)")
        case .failure(let error):
            // Log the error. The PreloadTaskManager will handle the task status update.
            BMLogger.shared.error("performPreload: Delegate reported failure for key: \(key), Error: \(error)")
        }
    }

    func getLoaderDelegate() -> BMAssetLoaderDelegate? {
        return self.loaderDelegate
    }

    func getCacheManager() -> BMCacheManager? {
        return self.cacheManager
    }
}

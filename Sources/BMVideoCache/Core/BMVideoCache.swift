import Foundation
import AVKit
public final class BMVideoCache {
    public static let shared = BMVideoCache()
    private var configuration: BMCacheConfiguration
    private var cacheManager: BMCacheManager?
    private var loaderDelegate: BMAssetLoaderDelegate?
    private let delegateQueue = DispatchQueue(label: "com.bmvideocache.assetloader.delegate.queue")
    private let initializationActor = InitializationActor()
    private var autoInitTask: Task<Void, Error>?
    private init() {
        do {
            self.configuration = try BMCacheConfiguration.defaultConfiguration()
            Task { await BMLogger.shared.debug("BMVideoCache instance created with default config.") }
            autoInitTask = Task { await initialize() }
            #if os(iOS) || os(tvOS)
            NotificationCenter.default.addObserver(self,
                                                   selector: #selector(handleMemoryWarning),
                                                   name: UIApplication.didReceiveMemoryWarningNotification,
                                                   object: nil)
            #endif
        } catch {
            Task { await BMLogger.shared.error("BMVideoCache: Could not create default configuration. Error: \(error)") }
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
            await BMLogger.shared.warning("Memory warning received, pressure level: \(currentMemoryPressureLevel), clearing cache data")
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
            await BMLogger.shared.info("Memory pressure level manually set to: \(level)")
            await clearCacheBasedOnMemoryPressure()
        }
    }
    public func ensureInitialized() async {
        if let task = await initializationActor.getTask() {
            do {
                _ = try await task.value
            } catch {
                Task { await BMLogger.shared.error("BMVideoCache initialization failed during ensureInitialized: \(error)") }
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
                Task { await BMLogger.shared.info("Initializing BMVideoCache...") }
                let createdManager = await BMCacheManager.create(configuration: self.configuration)
                self.cacheManager = createdManager
                guard let manager = self.cacheManager else {
                     Task { await BMLogger.shared.error("BMVideoCache: CacheManager is nil after creation attempt.") }
                     throw InitializationError.cacheManagerCreationFailed
                 }
                self.loaderDelegate = BMAssetLoaderDelegate(cacheManager: manager, config: self.configuration)
                Task { await BMLogger.shared.info("BMVideoCache initialized successfully.") }
            }
            await initializationActor.setTask(newTask)
        } else {
            Task { await BMLogger.shared.debug("BMVideoCache initialization already started or completed.") }
        }
        await waitUntilInitialized()
    }
    @MainActor
    public func reconfigure(with configuration: BMCacheConfiguration, preserveExistingCache: Bool = true) async -> Result<Void, BMVideoCacheError> {
        autoInitTask?.cancel()
        Task { await BMLogger.shared.info("Reconfiguring BMVideoCache with new configuration...") }
        let oldManager = self.cacheManager
        self.configuration = configuration
        let newTask = Task<Void, Error> {
            let createdManager = await BMCacheManager.create(configuration: self.configuration)
            if preserveExistingCache, let oldMgr = oldManager {
                Task { await BMLogger.shared.info("Migrating existing cache data to new configuration...") }
                await migrateCache(from: oldMgr, to: createdManager)
            }
            self.cacheManager = createdManager
            guard let manager = self.cacheManager else {
                Task { await BMLogger.shared.error("BMVideoCache: CacheManager is nil after reconfiguration attempt.") }
                throw InitializationError.cacheManagerCreationFailed
            }
            self.loaderDelegate = BMAssetLoaderDelegate(cacheManager: manager, config: self.configuration)
            if !preserveExistingCache, let oldMgr = oldManager {
                await oldMgr.clearAllCache()
            }
            Task { await BMLogger.shared.info("BMVideoCache reconfiguration complete.") }
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
        Task { await BMLogger.shared.info("Migrating \(stats.totalItemCount) cache items...") }
        Task { await BMLogger.shared.info("Cache migration completed.") }
    }
    private func waitUntilInitialized() async {
        guard let task = await initializationActor.getTask() else {
            Task { await BMLogger.shared.error("waitUntilInitialized called before initialization task was created.") }
            return
        }
        do {
            _ = try await task.value
            Task { await BMLogger.shared.debug("Initialization confirmed complete.") }
        } catch {
            Task { await BMLogger.shared.error("BMVideoCache initialization failed: \(error). Subsequent operations might fail.") }
        }
    }
    private func waitUntilInitializedWithError() async throws {
        guard let task = await initializationActor.getTask() else {
            let error = BMVideoCacheError.initializationFailed("Initialization task not created")
            Task { await BMLogger.shared.error("\(error)") }
            throw error
        }
        do {
            _ = try await task.value
            Task { await BMLogger.shared.debug("Initialization confirmed complete.") }
        } catch {
            let wrappedError = BMVideoCacheError.initializationFailed("\(error)")
            Task { await BMLogger.shared.error("BMVideoCache initialization failed: \(error)") }
            throw wrappedError
        }
    }
    public func asset(for originalURL: URL) async -> Result<AVURLAsset, BMVideoCacheError> {
        await ensureInitialized()
        guard let currentLoaderDelegate = self.loaderDelegate else {
             Task { await BMLogger.shared.error("BMVideoCache initialization failed or loaderDelegate is nil. Returning standard asset for URL: \(originalURL)") }
             return .failure(.notInitialized)
         }
        guard var components = URLComponents(url: originalURL, resolvingAgainstBaseURL: false) else {
            Task { await BMLogger.shared.warning("Could not create URLComponents for \(originalURL).") }
            return .failure(.invalidURL(originalURL))
        }
        let originalScheme = components.scheme
        let cachePrefix = configuration.cacheSchemePrefix
        components.scheme = "\(cachePrefix)\(originalScheme ?? "http")"
        guard let cacheURL = components.url else {
            Task { await BMLogger.shared.warning("Could not create cacheURL for \(originalURL).") }
             return .failure(.invalidURL(originalURL))
        }
        Task { await BMLogger.shared.debug("Creating cached asset for URL: \(cacheURL)") }
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
             Task { await BMLogger.shared.warning("BMVideoCache clearCache() called but cacheManager is nil (initialization failed?).") }
             return .failure(.notInitialized)
        }
        await manager.clearAllCache()
        return .success(())
    }
    public func calculateCurrentCacheSize() async -> Result<UInt64, BMVideoCacheError> {
        await ensureInitialized()
        guard let manager = cacheManager else {
             Task { await BMLogger.shared.warning("BMVideoCache calculateCurrentCacheSize() called but cacheManager is nil (initialization failed?).") }
             return .failure(.notInitialized)
        }
        return .success(await manager.getCurrentCacheSize())
    }
    public func getCacheStatistics() async -> Result<BMCacheStatistics, BMVideoCacheError> {
        await ensureInitialized()
        guard let manager = cacheManager else {
            Task { await BMLogger.shared.warning("BMVideoCache getCacheStatistics() called but cacheManager is nil (initialization failed?).") }
            return .failure(.notInitialized)
        }
        return .success(await manager.getStatistics())
    }
    public func setCachePriority(for url: URL, priority: CachePriority) async -> Result<Void, BMVideoCacheError> {
        await ensureInitialized()
        guard let manager = cacheManager else {
            Task { await BMLogger.shared.warning("BMVideoCache setCachePriority() called but cacheManager is nil (initialization failed?).") }
            return .failure(.notInitialized)
        }
        await manager.setCachePriority(for: url, priority: priority)
        return .success(())
    }
    public func setExpirationDate(for url: URL, date: Date?) async -> Result<Void, BMVideoCacheError> {
        await ensureInitialized()
        guard let manager = cacheManager else {
            Task { await BMLogger.shared.warning("BMVideoCache setExpirationDate() called but cacheManager is nil (initialization failed?).") }
            return .failure(.notInitialized)
        }
        await manager.setExpirationDate(for: url, date: date)
        return .success(())
    }
    public func preload(urls: [URL], length: Int64 = 10 * 1024 * 1024, priority: CachePriority = .normal) async -> Result<[UUID], BMVideoCacheError> {
        await ensureInitialized()
        guard let manager = cacheManager else {
             Task { await BMLogger.shared.warning("BMVideoCache preload() called but cacheManager is nil (initialization failed?).") }
             return .failure(.notInitialized)
        }
        Task { await BMLogger.shared.info("Initiating async preload for \(urls.count) URLs with length \(length).") }
        let taskManager = BMPreloadTaskManager.shared
        var taskIds: [UUID] = []
        for url in urls {
            let key = await manager.cacheKey(for: url)
            let taskId = await taskManager.addTask(url: url, key: key, length: length, priority: priority)
            taskIds.append(taskId)
            Task { await BMLogger.shared.debug("Added preload task \(taskId) for: \(url.lastPathComponent)") }
        }
        let localTaskIdsCount = taskIds.count
        Task { await BMLogger.shared.info("Added \(localTaskIdsCount) preload tasks to queue.") }
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
            Task { await BMLogger.shared.info("Cancelled preload task: \(taskId)") }
            return .success(())
        } else {
            Task { await BMLogger.shared.warning("Failed to cancel preload task: \(taskId) (not found or already completed)") }
            return .failure(.operationFailed("Task not found or already completed"))
        }
    }
    public func cancelAllPreloads() async -> Result<Void, BMVideoCacheError> {
        await ensureInitialized()
        let taskManager = BMPreloadTaskManager.shared
        await taskManager.cancelAllTasks()
        Task { await BMLogger.shared.info("Cancelled all preload tasks") }
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
        }
        return .success(statusString)
    }
    public func getPreloadStatistics() async -> Result<(created: UInt64, completed: UInt64, failed: UInt64, cancelled: UInt64), BMVideoCacheError> {
        await ensureInitialized()
        let taskManager = BMPreloadTaskManager.shared
        let stats = await taskManager.getStatistics()
        return .success(stats)
    }
    public func setMaxConcurrentPreloads(count: Int) async -> Result<Void, BMVideoCacheError> {
        await ensureInitialized()
        guard count > 0 else {
            return .failure(.operationFailed("Max concurrent preloads must be greater than 0"))
        }
        let taskManager = BMPreloadTaskManager.shared
        await taskManager.setMaxConcurrentTasks(count)
        Task { await BMLogger.shared.info("Set max concurrent preloads to \(count)") }
        return .success(())
    }
    internal func _internalPreload(url: URL, length: Int64) async {
        await ensureInitialized()
        guard let manager = cacheManager else {
            Task { await BMLogger.shared.warning("Internal preload called but cacheManager is nil") }
            return
        }
        await manager.preloadData(for: url, length: length)
    }
    public func configureLogger(level: BMLogger.LogLevel, fileLoggingEnabled: Bool = false, logFileURL: URL? = nil) async {
        await ensureInitialized()
        await BMLogger.shared.setLogLevel(level)
        await BMLogger.shared.setupFileLogging(enabled: fileLoggingEnabled, fileURL: logFileURL)
    }
    public enum BMVideoCacheError: Error, CustomStringConvertible {
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
}

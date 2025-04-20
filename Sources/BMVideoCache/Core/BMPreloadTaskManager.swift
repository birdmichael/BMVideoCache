import Foundation
import Combine

fileprivate var currentBatchTasks: [BMPreloadTaskManager.PreloadTask] = []
fileprivate var batchProcessingEnabled: Bool = false
fileprivate var batchSize: Int = 3
internal actor BMPreloadTaskManager {
    static let shared = BMPreloadTaskManager()
    enum TaskStatus: Equatable {
        case queued
        case running
        case completed
        case failed(Error)
        case cancelled
        case paused

        var statusString: String {
            switch self {
            case .queued:
                return "queued"
            case .running:
                return "running"
            case .completed:
                return "completed"
            case .cancelled:
                return "cancelled"
            case .failed:
                return "failed"
            case .paused:
                return "paused"
            }
        }

        static func == (lhs: TaskStatus, rhs: TaskStatus) -> Bool {
            switch (lhs, rhs) {
            case (.queued, .queued): return true
            case (.running, .running): return true
            case (.completed, .completed): return true
            case (.cancelled, .cancelled): return true
            case (.failed, .failed): return true
            case (.paused, .paused): return true
            default: return false
            }
        }
    }
    struct PreloadTask: Identifiable, Equatable {
        let id: UUID
        let url: URL
        let key: String
        let length: Int64
        var priority: CachePriority
        let creationTime: Date
        var status: TaskStatus
        var startTime: Date?
        var endTime: Date?
        var timeoutSeconds: TimeInterval
        var timeoutTask: Task<Void, Never>?
        static func == (lhs: PreloadTask, rhs: PreloadTask) -> Bool {
            return lhs.id == rhs.id
        }
    }
    private var taskQueue: [PreloadTask] = []
    private var runningTasks: [PreloadTask] = []
    private var completedTasks: [PreloadTask] = []
    private var maxConcurrentTasks: Int = 3
    private(set) var totalTasksCreated: UInt64 = 0
    private(set) var totalTasksCompleted: UInt64 = 0
    private(set) var totalTasksFailed: UInt64 = 0
    private(set) var totalTasksCancelled: UInt64 = 0
    private var taskRetryCount: [UUID: Int] = [:]  
    private let maxRetryCount: Int = 3
    private var dynamicPriorityEnabled: Bool = true
    private init() {}
    func setMaxConcurrentTasks(_ count: Int) {
        guard count > 0 else { return }
        maxConcurrentTasks = count
        processQueue()
    }
    func addTask(url: URL, key: String, length: Int64, priority: CachePriority = .normal, timeoutSeconds: TimeInterval = 60) -> UUID {
        Task { BMLogger.shared.debug("[Preload] addTask key: \(key) len: \(length) priority: \(priority)") }
        let taskId = UUID()

        // Ensure metadata exists before adding the task
        // We need the cache manager instance for this.
        // Let's assume BMVideoCache.shared provides it.
        Task {
             // Wait for initialization first
            await BMVideoCache.shared.ensureInitialized()
            if let manager = BMVideoCache.shared.getCacheManager() {
                 // Create or update metadata (use async version)
                 _ = await manager.createOrUpdateMetadata(for: key, originalURL: url, updateAccessTime: false)
                 Task { BMLogger.shared.debug("Ensured metadata for preload key: \(key)") }
             } else {
                 Task { BMLogger.shared.error("Failed to get CacheManager while ensuring metadata for preload key: \(key)") }
             }
        }

        let task = PreloadTask(
            id: taskId,
            url: url,
            key: key,
            length: length,
            priority: priority,
            creationTime: Date(),
            status: .queued,
            startTime: nil,
            endTime: nil,
            timeoutSeconds: timeoutSeconds,
            timeoutTask: nil
        )
        insertTaskInSortedOrder(task)
        totalTasksCreated += 1
        processQueue()
        return taskId
    }
    private func insertTaskInSortedOrder(_ task: PreloadTask) {
        if taskQueue.isEmpty {
            taskQueue.append(task)
            return
        }
        var low = 0
        var high = taskQueue.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let midTask = taskQueue[mid]
            if task.priority > midTask.priority {
                high = mid - 1
            } else if task.priority < midTask.priority {
                low = mid + 1
            } else {
                if task.creationTime < midTask.creationTime {
                    high = mid - 1
                } else {
                    low = mid + 1
                }
            }
        }
        taskQueue.insert(task, at: low)
    }
    func cancelTask(id: UUID) async -> Bool {
        BMLogger.shared.debug("[Preload] cancelTask id: \(id)")

        // 首先检查已完成的任务列表
        if let index = completedTasks.firstIndex(where: { $0.id == id }) {
            var task = completedTasks[index]
            // 如果任务已经完成，我们不能真正取消它，但可以标记为取消
            if task.status == .completed {
                BMLogger.shared.warning("Cannot cancel already completed task: \(id)")
                return false
            }
            task.status = .cancelled
            completedTasks[index] = task
            totalTasksCancelled += 1
            return true
        }

        // 检查队列中的任务
        if let index = taskQueue.firstIndex(where: { $0.id == id }) {
            var task = taskQueue[index]
            task.status = .cancelled
            completedTasks.append(task)
            taskQueue.remove(at: index)
            totalTasksCancelled += 1
            return true
        }

        // 检查正在运行的任务
        if let index = runningTasks.firstIndex(where: { $0.id == id }) {
            var task = runningTasks[index]
            task.timeoutTask?.cancel()
            task.status = .cancelled
            task.endTime = Date()
            completedTasks.append(task)
            runningTasks.remove(at: index)
            totalTasksCancelled += 1
            processQueue()
            return true
        }

        // 如果找不到任务，记录警告并返回失败
        BMLogger.shared.warning("Attempted to cancel non-existent task: \(id)")
        return false
    }
    func cancelAllTasks() async {
        BMLogger.shared.info("[Preload] cancelAllTasks called, queue: \(taskQueue.count), running: \(runningTasks.count)")
        for var task in taskQueue {
            task.status = .cancelled
            completedTasks.append(task)
            totalTasksCancelled += 1
        }
        taskQueue.removeAll()
        for var task in runningTasks {
            task.status = .cancelled
            task.endTime = Date()
            completedTasks.append(task)
            totalTasksCancelled += 1
        }
        runningTasks.removeAll()
    }
    func getTaskStatus(id: UUID) -> TaskStatus? {
        if let task = taskQueue.first(where: { $0.id == id }) {
            return task.status
        }
        if let task = runningTasks.first(where: { $0.id == id }) {
            return task.status
        }
        if let task = completedTasks.first(where: { $0.id == id }) {
            return task.status
        }
        return nil
    }
    func getAllTasks() -> [PreloadTask] {
        return taskQueue + runningTasks + completedTasks
    }
    func getQueuedTasks() -> [PreloadTask] {
        return taskQueue
    }
    func getRunningTasks() -> [PreloadTask] {
        return runningTasks
    }
    func getCompletedTasks() -> [PreloadTask] {
        return completedTasks
    }
    func clearCompletedTasksHistory(keepLast: Int = 50) {
        Task { BMLogger.shared.debug("[Preload] clearCompletedTasksHistory, keepLast: \(keepLast)") }
        if completedTasks.count > keepLast {
            completedTasks = Array(completedTasks.suffix(keepLast))
        }
    }
    func getStatistics() -> (created: UInt64, completed: UInt64, failed: UInt64, cancelled: UInt64) {
        return (totalTasksCreated, totalTasksCompleted, totalTasksFailed, totalTasksCancelled)
    }
    func taskCompleted(id: UUID, success: Bool, error: Error? = nil) async {
        let key = runningTasks.first(where: { $0.id == id })?.key ?? "unknown"
        if success {
            BMLogger.shared.info("[Preload] 任务完成: \(key), id: \(id)")
        } else {
            BMLogger.shared.error("[Preload] 任务失败: \(key), id: \(id), error: \(String(describing: error))")
        }
        if let index = runningTasks.firstIndex(where: { $0.id == id }) {
            var task = runningTasks[index]
            if success {
                task.status = .completed
                totalTasksCompleted += 1
            } else if let err = error {
                task.status = .failed(err)
                totalTasksFailed += 1
            } else {
                task.status = .failed(NSError(domain: "BMVideoCache", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown error"]))
                totalTasksFailed += 1
            }
            task.endTime = Date()
            completedTasks.append(task)
            runningTasks.remove(at: index)
            processQueue()
        }
    }
    private var batchProcessingEnabled = true
    private var batchSize = 3
    private var currentBatchTasks: [PreloadTask] = []
    func setBatchProcessing(enabled: Bool, batchSize: Int = 3) {
        self.batchProcessingEnabled = enabled
        self.batchSize = max(1, batchSize)
        processQueue()
    }
    private func processQueue() {
        if runningTasks.count >= maxConcurrentTasks || taskQueue.isEmpty {
            return
        }
        
        if dynamicPriorityEnabled {
            updateTaskPriorities()
        }
        
        let availableSlots = maxConcurrentTasks - runningTasks.count
        let tasksToStart = min(availableSlots, taskQueue.count)
        
        if batchProcessingEnabled && tasksToStart > 1 {
            startBatchTasks(count: tasksToStart)
        } else {
            for _ in 0..<tasksToStart {
                startNextTask()
            }
        }
    }
    private func startNextTask() {
        guard !taskQueue.isEmpty && runningTasks.count < maxConcurrentTasks else {
            return
        }
        var task = taskQueue.removeFirst()
        task.status = .running
        task.startTime = Date()
        runningTasks.append(task)
        Task {
            await startTask(task)
        }
    }
    private func startBatchTasks(count: Int) {
        let actualBatchSize = min(count, batchSize)
        currentBatchTasks = []
        for _ in 0..<actualBatchSize {
            guard !taskQueue.isEmpty else { break }
            var task = taskQueue.removeFirst()
            task.status = .running
            task.startTime = Date()
            runningTasks.append(task)
            currentBatchTasks.append(task)
        }
        if !currentBatchTasks.isEmpty {
            Task {
                await processBatch(currentBatchTasks)
                currentBatchTasks = []
            }
        }
    }
    private func processBatch(_ tasks: [PreloadTask]) async {
        await withTaskGroup(of: Void.self) { group in
            for task in tasks {
                group.addTask {
                    await self.startTask(task)
                }
            }
        }
    }
    private func startTask(_ task: PreloadTask) async {
        let taskId = task.id
        
        guard let loaderDelegate = BMVideoCache.shared.getLoaderDelegate() else {
            let error = NSError(domain: "BMVideoCache", code: -1, userInfo: [NSLocalizedDescriptionKey: "LoaderDelegate not initialized"])
            await taskCompleted(id: taskId, success: false, error: error)
            return
        }
        
        let currentRetryCount = taskRetryCount[taskId] ?? 0
        
        do {
            let result = await loaderDelegate.startPreload(forKey: task.key, length: task.length)
            
            switch result {
            case .success:
                await taskCompleted(id: taskId, success: true, error: nil)
                taskRetryCount.removeValue(forKey: taskId) 
            case .failure(let error):
                if let nsError = error as NSError?, nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
                    taskCancelled(id: taskId)
                    taskRetryCount.removeValue(forKey: taskId)
                } else if currentRetryCount < maxRetryCount {
                    taskRetryCount[taskId] = currentRetryCount + 1
                    BMLogger.shared.warning("预加载失败，正在重试 (\(currentRetryCount + 1)/\(maxRetryCount)): \(task.key)")
                    
                    try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(currentRetryCount)) * 1_000_000_000))
                    if !Task.isCancelled {
                        await startTask(task)
                    }
                } else {
                    BMLogger.shared.error("预加载失败，已达最大重试次数: \(task.key)")
                    await taskCompleted(id: taskId, success: false, error: error)
                    taskRetryCount.removeValue(forKey: taskId)
                }
            }
        } catch {
            if currentRetryCount < maxRetryCount {
                taskRetryCount[taskId] = currentRetryCount + 1
                BMLogger.shared.warning("预加载异常，正在重试 (\(currentRetryCount + 1)/\(maxRetryCount)): \(task.key)")
                
                try? await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(currentRetryCount)) * 1_000_000_000))
                if !Task.isCancelled {
                    await startTask(task)
                }
            } else {
                BMLogger.shared.error("预加载异常，已达最大重试次数: \(task.key)")
                await taskCompleted(id: taskId, success: false, error: error)
                taskRetryCount.removeValue(forKey: taskId)
            }
        }
    }

    // Helper function to mark task as cancelled (might need adjustment based on existing cancel logic)
    private func taskCancelled(id: UUID) {
        if let index = runningTasks.firstIndex(where: { $0.id == id }) {
            var task = runningTasks[index]
            task.status = .cancelled
            task.endTime = Date()
            completedTasks.append(task)
            runningTasks.remove(at: index)
            totalTasksCancelled += 1
            processQueue() // Process queue as a slot is freed
        } else {
            // Task might have been cancelled while queued, handled by cancelTask(id:)
            Task {
                BMLogger.shared.warning("Attempted to mark non-running task as cancelled via taskCancelled(id: \(id))")
            }
        }
    }

    private func handleTaskTimeout(taskId: UUID) async {
       // This method is no longer needed as timeout is implicitly handled by URLSession or potentially BMDataLoader logic if required.
       // If explicit timeout *different* from URLSession is needed, it should be re-implemented within startTask or BMDataLoader.
        BMLogger.shared.warning("handleTaskTimeout called, but timeout logic has been removed/delegated. Task ID: \(taskId)")
    }

    private func sortQueue() {
        taskQueue.sort { (task1, task2) -> Bool in
            if task1.priority != task2.priority {
                return task1.priority > task2.priority
            }
            return task1.creationTime < task2.creationTime
        }
    }
    
    private func updateTaskPriorities() {
        guard !taskQueue.isEmpty else { return }
        
        for i in 0..<taskQueue.count {
            var task = taskQueue[i]
            
            if Date().timeIntervalSince(task.creationTime) > 30 && task.priority != .high {
                let newPriority: CachePriority = task.priority == .normal ? .high : .normal
                task.priority = newPriority
                taskQueue[i] = task
            }
        }
        
        sortQueue()
    }
    
    func enableDynamicPriority(_ enabled: Bool) {
        dynamicPriorityEnabled = enabled
    }
    
    func pauseTask(id: UUID) async -> Bool {
        if let index = taskQueue.firstIndex(where: { $0.id == id }) {
            var task = taskQueue[index]
            task.status = .paused
            taskQueue[index] = task
            return true
        } else if let index = runningTasks.firstIndex(where: { $0.id == id }) {
            await cancelTask(id: id)
            var task = runningTasks[index]
            task.status = .paused
            taskQueue.append(task)
            runningTasks.remove(at: index)
            sortQueue()
            return true
        }
        return false
    }
    
    func resumeTask(id: UUID) async -> Bool {
        if let index = taskQueue.firstIndex(where: { $0.id == id && $0.status == .paused }) {
            var task = taskQueue[index]
            task.status = .queued
            taskQueue[index] = task
            sortQueue()
            processQueue()
            return true
        }
        return false
    }
}

import Foundation
internal actor BMPreloadTaskManager {
    static let shared = BMPreloadTaskManager()
    enum TaskStatus {
        case queued
        case running
        case completed
        case failed(Error)
        case cancelled
    }
    struct PreloadTask: Identifiable, Equatable {
        let id: UUID
        let url: URL
        let key: String
        let length: Int64
        let priority: CachePriority
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
    private init() {}
    func setMaxConcurrentTasks(_ count: Int) {
        guard count > 0 else { return }
        maxConcurrentTasks = count
        processQueue()
    }
    func addTask(url: URL, key: String, length: Int64, priority: CachePriority = .normal, timeoutSeconds: TimeInterval = 60) -> UUID {
        let taskId = UUID()
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
    func cancelTask(id: UUID) -> Bool {
        if let index = taskQueue.firstIndex(where: { $0.id == id }) {
            var task = taskQueue[index]
            task.status = .cancelled
            completedTasks.append(task)
            taskQueue.remove(at: index)
            totalTasksCancelled += 1
            return true
        }
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
        return false
    }
    func cancelAllTasks() {
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
        if completedTasks.count > keepLast {
            completedTasks = Array(completedTasks.suffix(keepLast))
        }
    }
    func getStatistics() -> (created: UInt64, completed: UInt64, failed: UInt64, cancelled: UInt64) {
        return (totalTasksCreated, totalTasksCompleted, totalTasksFailed, totalTasksCancelled)
    }
    func taskCompleted(id: UUID, success: Bool, error: Error? = nil) {
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
        let timeoutTask = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(task.timeoutSeconds * 1_000_000_000))
                if !Task.isCancelled {
                    await handleTaskTimeout(taskId: taskId)
                }
            } catch {
                
            }
        }
        if let index = runningTasks.firstIndex(where: { $0.id == task.id }) {
            runningTasks[index].timeoutTask = timeoutTask
        }
        await BMVideoCache.shared._internalPreload(url: task.url, length: task.length)
        timeoutTask.cancel()
        taskCompleted(id: task.id, success: true)
    }
    private func handleTaskTimeout(taskId: UUID) async {
        if let index = runningTasks.firstIndex(where: { $0.id == taskId }) {
            let task = runningTasks[index]
            let timeoutError = NSError(
                domain: "BMVideoCache",
                code: -1001,
                userInfo: [NSLocalizedDescriptionKey: "Preload task timed out after \(task.timeoutSeconds) seconds"]
            )
            taskCompleted(id: taskId, success: false, error: timeoutError)
            Task { await BMLogger.shared.warning("Preload task \(taskId) for URL \(task.url.lastPathComponent) timed out after \(task.timeoutSeconds) seconds") }
        }
    }
    private func sortQueue() {
        taskQueue.sort { (task1, task2) -> Bool in
            if task1.priority != task2.priority {
                return task1.priority > task2.priority
            }
            return task1.creationTime < task2.creationTime
        }
    }
}

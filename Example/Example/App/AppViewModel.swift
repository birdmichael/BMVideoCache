import Foundation
import Combine
import BMVideoCache
import SwiftUI

@MainActor
class AppViewModel: ObservableObject {
    @Published var videos: [VideoModel] = VideoModel.samples
    @Published var selectedVideo: VideoModel?
    
    @Published var preloadingVideos: Set<URL> = []
    @Published var preloadProgress: [URL: Double] = [:]
    private var preloadTaskIds: [URL: UUID] = [:]
    
    @Published var cacheStatistics: BMCacheStatistics?
    @Published var maxCacheSize: UInt64 = 0
    @Published var currentCacheSize: UInt64 = 0
    
    @Published var memoryPressureLevel: BMVideoCache.MemoryPressureLevel = .low
    
    private var cancellables = Set<AnyCancellable>()
    // 完全移除定时器，改为按需更新
    
    init() {
        Task {
            await BMVideoCache.shared.ensureInitialized()
            await loadCacheStatistics()
            await loadCacheConfiguration()
        }
    }
    
    func preloadVideo(_ video: VideoModel) async {
        guard !preloadingVideos.contains(video.url) else { return }
        
        preloadingVideos.insert(video.url)
        preloadProgress[video.url] = 0.0
        
        // 使用正确的preload API
        let result = await BMVideoCache.shared.preload(url: video.url)
        
        switch result {
        case .success(let taskId):
            // 保存任务ID用于后续取消
            preloadTaskIds[video.url] = taskId
            // 预加载已开始，进度更新由updateCacheStatus方法处理
            break
        case .failure:
            await MainActor.run {
                preloadingVideos.remove(video.url)
                preloadProgress.removeValue(forKey: video.url)
            }
        }
    }
    
    func cancelPreload(for video: VideoModel) async {
        if let taskId = preloadTaskIds[video.url] {
            // 使用正确的API取消预加载任务
            _ = await BMVideoCache.shared.cancelPreload(taskId: taskId)
            preloadTaskIds.removeValue(forKey: video.url)
        }
        preloadingVideos.remove(video.url)
        preloadProgress.removeValue(forKey: video.url)
        
        // 解决问题2: 关闭浏览时如果还在下载，则完全清除视频缓存
        let cacheStatus = await isVideoCached(video)
        if !cacheStatus.isComplete { // 使用isComplete来判断是否完成缓存
            await removeFromCache(url: video.url)
        }
    }
    
    // 添加缓存移除的扩展方法
    private func removeFromCache(url: URL) async {
        guard let cacheManager = BMVideoCache.shared.cacheManager else { return }
        // 使用正确的cacheKey生成方法
        let key = BMCacheManager.generateCacheKey(for: url)
        _ = await cacheManager.removeCache(for: key)
    }
    
    func cancelAllPreloads() async {
        // 查找正确的API方法
        for (_, taskId) in preloadTaskIds {
            _ = await BMVideoCache.shared.cancelPreload(taskId: taskId)
        }
        preloadTaskIds.removeAll()
        preloadingVideos.removeAll()
        preloadProgress.removeAll()
    }
    
    func isVideoCached(_ video: VideoModel) async -> (isCached: Bool, isComplete: Bool, cachedSize: UInt64, expectedSize: UInt64?) {
        let result = await BMVideoCache.shared.isURLCached(video.url)
        
        switch result {
        case .success(let status):
            return status
        case .failure:
            return (false, false, 0, nil)
        }
    }
    
    func clearCache() async {
        let result = await BMVideoCache.shared.clearCache()
        if case .success = result {
            await loadCacheStatistics()
        }
    }
    
    func clearLowPriorityCache() async {
        // BMVideoCache.shared不直接暴露clearLowPriorityCache方法
        // 我们可以使用内存压力级别来间接实现
        let oldLevel = memoryPressureLevel
        BMVideoCache.shared.setMemoryPressureLevel(.medium) // 中等压力会清除低优先级缓存
        
        // 将内存压力级别还原至原来的状态
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.setMemoryPressureLevel(oldLevel)
        }
        
        await loadCacheStatistics()
    }
    
    func loadCacheStatistics() async {
        let statsResult = await BMVideoCache.shared.getCacheStatistics()
        guard case .success(let stats) = statsResult else { return }
        
        cacheStatistics = stats
        
        let sizeResult = await BMVideoCache.shared.calculateCurrentCacheSize()
        if case .success(let size) = sizeResult {
            currentCacheSize = size
        }
    }
    
    func loadCacheConfiguration() async {
        // 因为我们不能直接获取配置，设置一个合理的默认值
        // 计算缓存大小
        let sizeResult = await BMVideoCache.shared.calculateCurrentCacheSize()
        if case .success(let size) = sizeResult {
            // 设置最大缓存为当前的2倍或至少100MB
            maxCacheSize = max(size * 2, UInt64(100 * 1024 * 1024))
        } else {
            // 默认值
            maxCacheSize = UInt64(100 * 1024 * 1024) // 100MB
        }
    }
    
    func updateCacheSize(_ newSize: UInt64) async {
        // 由于我们无法访问当前的缓存目录，我们只能创建一个新的配置使用默认路径
        // 这里使用默认配置但改变最大缓存大小
        let config = BMCacheConfiguration(
            cacheDirectoryURL: FileManager.default.temporaryDirectory.appendingPathComponent("BMVideoCache"),
            maxCacheSizeInBytes: newSize
        )
        
        let result = await BMVideoCache.shared.reconfigure(with: config)
        
        if case .success = result {
            maxCacheSize = newSize
            await loadCacheStatistics() // 重新加载统计数据
        }
    }
    
    func setMemoryPressureLevel(_ level: BMVideoCache.MemoryPressureLevel) {
        BMVideoCache.shared.setMemoryPressureLevel(level)
        memoryPressureLevel = level
    }
    
    private func updateCacheStatus() async {
        for url in preloadingVideos {
            let result = await BMVideoCache.shared.isURLCached(url)
            
            if case .success(let status) = result, let expectedSize = status.expectedSize, expectedSize > 0 {
                let calculatedProgress = Double(status.cachedSize) / Double(expectedSize)
                await MainActor.run {
                    if calculatedProgress > (preloadProgress[url] ?? 0.0) {
                        preloadProgress[url] = calculatedProgress
                    }
                    
                    if status.isComplete {
                        preloadProgress[url] = 1.0
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            self.preloadingVideos.remove(url)
                            self.preloadTaskIds.removeValue(forKey: url)
                        }
                    }
                }
            }
        }
    }
}

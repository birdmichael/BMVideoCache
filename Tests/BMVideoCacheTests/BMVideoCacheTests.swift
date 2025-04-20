import XCTest
import AVKit
@testable import BMVideoCache

final class BMVideoCacheTests: XCTestCase {
    
    private var videoCache: BMVideoCache!
    private var testDirectoryURL: URL!
    
    override func setUp() async throws {
        // 为测试创建临时目录
        let temporaryDirectory = FileManager.default.temporaryDirectory
        testDirectoryURL = temporaryDirectory.appendingPathComponent("BMVideoCacheTests_\(UUID().uuidString)")
        
        try FileManager.default.createDirectory(at: testDirectoryURL, withIntermediateDirectories: true)
        
        // 创建自定义配置
        let config = BMCacheConfiguration(
            cacheDirectoryURL: testDirectoryURL,
            maxCacheSizeInBytes: 100 * 1024 * 1024, // 100MB
            preloadTaskTimeout: 30,
            cleanupInterval: 10
        )
        
        // 重新配置缓存实例
        videoCache = BMVideoCache.shared
        let result = await videoCache.reconfigure(with: config)
        if case .failure(let error) = result {
            XCTFail("重新配置缓存失败：\(error)")
        }
    }
    
    override func tearDown() async throws {
        // 清理测试目录
        if let url = testDirectoryURL, FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                print("警告：无法删除测试目录，可能需要手动清理：\(error.localizedDescription)")
                // 我们不抛出异常，让测试继续执行
                // 在实际应用中，临时目录会由操作系统最终清理
            }
        }
    }

    func testInitialization() async {
        // 确保能够正确初始化
        await videoCache.ensureInitialized()
        
        // 验证缓存目录存在
        XCTAssertTrue(FileManager.default.fileExists(atPath: testDirectoryURL.path))
        
        print("缓存目录位置：\(testDirectoryURL.path)")
    }
    
    func testCalculateCacheSize() async {
        let sizeResult = await videoCache.calculateCurrentCacheSize()
        
        // 新的缓存应该是空的
        XCTAssertEqual(sizeResult, .success(0))
    }
    
    func testClearCache() async {
        // 测试清除缓存功能
        let result = await videoCache.clearCache()
        if case .failure(let error) = result {
            XCTFail("清除缓存失败：\(error)")
        }
    }
    
    func testGetCacheStatistics() async {
        let statsResult = await videoCache.getCacheStatistics()
        
        // 验证能成功获取统计信息
        if case .success(let stats) = statsResult {
            print("缓存统计信息：命中次数 = \(stats.hitCount), 未命中次数 = \(stats.missCount), 命中率 = \(stats.hitRate)")
            XCTAssertEqual(stats.hitCount, 0)
            XCTAssertEqual(stats.missCount, 0)
            XCTAssertEqual(stats.hitRate, 0)
        } else {
            XCTFail("获取缓存统计信息失败")
        }
    }
    
    func testMemoryPressureLevel() {
        // 测试内存压力级别设置
        let initialLevel = videoCache.getCurrentMemoryPressureLevel()
        XCTAssertEqual(initialLevel, .low)
        
        videoCache.setMemoryPressureLevel(.medium)
        XCTAssertEqual(videoCache.getCurrentMemoryPressureLevel(), .medium)
        
        videoCache.setMemoryPressureLevel(.high)
        XCTAssertEqual(videoCache.getCurrentMemoryPressureLevel(), .high)
        
        videoCache.setMemoryPressureLevel(.critical)
        XCTAssertEqual(videoCache.getCurrentMemoryPressureLevel(), .critical)
        
        // 重置到低级别
        videoCache.setMemoryPressureLevel(.low)
    }
    
    // 使用真实视频URL的缓存测试
    func testRealVideoURLCaching() async throws {
        // 使用真实的Google示例视频
        let videoURLs = [
            URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4")!,
            URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ElephantsDream.mp4")!
        ]
        
        print("===== 开始真实视频缓存测试 =====")
        
        // 确保缓存是空的
        let clearResult = await videoCache.clearCache()
        if case .failure(let error) = clearResult {
            XCTFail("清除缓存失败：\(error)")
        }
        
        // 检查初始缓存大小
        let initialSizeResult = await videoCache.calculateCurrentCacheSize()
        if case .success(let initialSize) = initialSizeResult {
            print("初始缓存大小: \(initialSize) 字节")
            XCTAssertEqual(initialSize, 0, "缓存清除后应该为0字节")
        }
        
        // 预加载第一个视频
        print("开始预加载第一个视频: \(videoURLs[0].lastPathComponent)")
        _ = await videoCache.preload(url: videoURLs[0])
        
        // 等待预加载进行一段时间
        print("等待预加载进行...")
        try await Task.sleep(nanoseconds: 5 * 1_000_000_000) // 等待5秒
        
        // 检查缓存状态
        let statusResult = await videoCache.isURLCached(videoURLs[0])
        if case .success(let status) = statusResult {
            print("预加载后状态 - 缓存: \(status.isCached), 完成: \(status.isComplete), 大小: \(status.cachedSize) 字节")
            if status.isCached {
                print("预加载成功")
            } else {
                print("预加载在5秒内未能缓存数据")
            }
        }
        
        // 创建并使用第一个视频的资产
        print("创建第一个视频的AVAsset...")
        let assetResult = await videoCache.asset(for: videoURLs[0])
        guard case .success(let asset) = assetResult else {
            XCTFail("创建AVAsset失败")
            return
        }
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        
        // 开始播放
        print("开始播放视频...")
        player.play()
        
        // 等待一段时间以允许播放继续
        try await Task.sleep(nanoseconds: 3 * 1_000_000_000) // 等待3秒
        player.pause()
        
        // 检查最终缓存大小
        let finalSizeResult = await videoCache.calculateCurrentCacheSize()
        if case .success(let finalSize) = finalSizeResult {
            print("最终缓存大小: \(finalSize) 字节")
            // 预期缓存大小应该大于0
            XCTAssertGreaterThan(finalSize, 0, "播放后缓存大小应该大于0")
        }
        
        // 检查统计信息
        let statsResult = await videoCache.getCacheStatistics()
        if case .success(let stats) = statsResult {
            print("缓存统计 - 命中次数: \(stats.hitCount), 丢失次数: \(stats.missCount), 命中率: \(stats.hitRate * 100)%, 项目数: \(stats.totalItemCount)")
            // 预期至少有一个缓存项
            XCTAssertGreaterThan(stats.totalItemCount, 0, "应该至少有一个缓存项")
        }
        
        print("===== 真实视频缓存测试完成 =====")
    }
}

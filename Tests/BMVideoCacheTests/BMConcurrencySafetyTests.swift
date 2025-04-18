import XCTest
@testable import BMVideoCache

final class BMConcurrencySafetyTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHelper.setupMockURLSession()
    }

    override class func tearDown() {
        TestHelper.tearDownMockURLSession()
        super.tearDown()
    }

    override func setUp() async throws {
        let result = await BMVideoCache.shared.clearCache()
        if case .failure(let error) = result {
            XCTFail("Failed to clear cache: \(error)")
        }

        await BMVideoCache.shared.configureLogger(level: .warning)
    }

    override func tearDown() async throws {
        let result = await BMVideoCache.shared.clearCache()
        if case .failure(let error) = result {
            XCTFail("Failed to clear cache: \(error)")
        }
    }



    func testConcurrentAssetCreationAndPreload() async throws {
        var assetURLs: [URL] = []
        var preloadURLs: [URL] = []

        for i in 0..<50 {
            assetURLs.append(URL(string: "https://example.com/asset-video\(i).mp4")!)
            preloadURLs.append(URL(string: "https://example.com/preload-video\(i).mp4")!)
        }

        // 注册模拟视频并直接添加到缓存
        TestHelper.registerMockVideos(for: assetURLs)
        TestHelper.registerMockVideos(for: preloadURLs)

        // 直接添加到缓存
        await TestHelper.setupCacheForTests(urls: assetURLs)

        await withTaskGroup(of: Void.self) { group in
            for url in assetURLs {
                group.addTask {
                    let result = await BMVideoCache.shared.asset(for: url)
                    if case .failure = result {
                        XCTFail("Failed to create asset for \(url)")
                    }
                }
            }

            for url in preloadURLs {
                group.addTask {
                    let result = await BMVideoCache.shared.preload(url: url, length: 1024)
                    if case .failure = result {
                        XCTFail("Failed to preload \(url)")
                    }
                }
            }
        }

        // 等待异步操作完成
        try await TestHelper.waitForAsyncOperations(timeout: 0.5)

        let cancelResult = await BMVideoCache.shared.cancelAllPreloads()
        if case .failure = cancelResult {
            XCTFail("Failed to cancel all preload tasks")
        }

        // 等待取消操作完成
        try await TestHelper.waitForAsyncOperations(timeout: 0.2)

        let statsResult = await BMVideoCache.shared.getCacheStatistics()
        guard case .success(let stats) = statsResult else {
            XCTFail("Failed to get cache statistics")
            return
        }

        XCTAssertNotNil(stats, "Cache statistics should not be nil")
    }

    func testConcurrentCacheOperations() async throws {
        let testURL = URL(string: "https://example.com/test-video.mp4")!

        // 注册模拟视频并直接添加到缓存
        TestHelper.registerMockVideo(for: testURL)
        await TestHelper.setupCacheForTest(url: testURL)

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                let result = await BMVideoCache.shared.setCachePriority(for: testURL, priority: .high)
                if case .failure = result {
                    XCTFail("Failed to set cache priority")
                }
            }

            group.addTask {
                let expirationDate = Date().addingTimeInterval(3600)
                let result = await BMVideoCache.shared.setExpirationDate(for: testURL, date: expirationDate)
                if case .failure = result {
                    XCTFail("Failed to set expiration date")
                }
            }

            group.addTask {
                let result = await BMVideoCache.shared.getCacheStatistics()
                if case .failure = result {
                    XCTFail("Failed to get cache statistics")
                }
            }

            group.addTask {
                let result = await BMVideoCache.shared.calculateCurrentCacheSize()
                if case .failure = result {
                    XCTFail("Failed to calculate cache size")
                }
            }
        }

        // 等待异步操作完成
        try await TestHelper.waitForAsyncOperations()
    }

    func testConcurrentPreloadOperations() async throws {
        var testURLs: [URL] = []
        for i in 0..<20 {
            testURLs.append(URL(string: "https://example.com/test-video\(i).mp4")!)
        }

        // 注册模拟视频
        TestHelper.registerMockVideos(for: testURLs)

        let preloadResult = await BMVideoCache.shared.preload(urls: testURLs, length: 1024)
        guard case .success(let taskIds) = preloadResult else {
            XCTFail("Failed to start batch preload")
            return
        }

        // 等待任务开始
        try await TestHelper.waitForAsyncOperations(timeout: 0.2)

        await withTaskGroup(of: Void.self) { group in
            for taskId in taskIds {
                group.addTask {
                    let result = await BMVideoCache.shared.getPreloadStatus(taskId: taskId)
                    if case .failure = result {
                        XCTFail("Failed to get task status for \(taskId)")
                    }
                }
            }

            if taskIds.count > 5 {
                for i in 0..<5 {
                    let taskId = taskIds[i]
                    group.addTask {
                        let result = await BMVideoCache.shared.cancelPreload(taskId: taskId)
                        if case .failure = result {
                            XCTFail("Failed to cancel task \(taskId)")
                        }
                    }
                }
            }

            group.addTask {
                let result = await BMVideoCache.shared.getPreloadStatistics()
                if case .failure = result {
                    XCTFail("Failed to get preload statistics")
                }
            }
        }

        // 等待异步操作完成
        try await TestHelper.waitForAsyncOperations(timeout: 0.2)

        let cancelResult = await BMVideoCache.shared.cancelAllPreloads()
        if case .failure = cancelResult {
            XCTFail("Failed to cancel all preload tasks")
        }

        // 等待取消操作完成
        try await TestHelper.waitForAsyncOperations(timeout: 0.2)
    }

    func testConcurrentReconfiguration() async throws {
        let testURL = URL(string: "https://example.com/test-video.mp4")!
        let anotherURL = URL(string: "https://example.com/another-video.mp4")!
        let preloadURL = URL(string: "https://example.com/preload-during-reconfig.mp4")!

        // 注册模拟视频并直接添加到缓存
        TestHelper.registerMockVideo(for: testURL)
        TestHelper.registerMockVideo(for: anotherURL)
        TestHelper.registerMockVideo(for: preloadURL)
        await TestHelper.setupCacheForTest(url: testURL)

        let currentConfig = try BMCacheConfiguration.defaultConfiguration()

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                let newConfig = BMCacheConfiguration(
                    cacheDirectoryURL: currentConfig.cacheDirectoryURL,
                    maxCacheSizeInBytes: currentConfig.maxCacheSizeInBytes * 2,
                    preloadTaskTimeout: currentConfig.preloadTaskTimeout,
                    requestTimeoutInterval: currentConfig.requestTimeoutInterval,
                    allowsCellularAccess: currentConfig.allowsCellularAccess,
                    maxConcurrentDownloads: currentConfig.maxConcurrentDownloads,
                    customHTTPHeaderFields: currentConfig.customHTTPHeaderFields,
                    cacheKeyNamer: currentConfig.cacheKeyNamer,
                    cacheSchemePrefix: currentConfig.cacheSchemePrefix,
                    defaultExpirationInterval: currentConfig.defaultExpirationInterval,
                    cleanupInterval: currentConfig.cleanupInterval,
                    cleanupStrategy: currentConfig.cleanupStrategy,
                    minimumDiskSpaceForCaching: currentConfig.minimumDiskSpaceForCaching
                )

                let result = await BMVideoCache.shared.reconfigure(with: newConfig, preserveExistingCache: true)
                if case .failure = result {
                    XCTFail("Failed to reconfigure")
                }
            }

            group.addTask {
                let result = await BMVideoCache.shared.asset(for: anotherURL)
                if case .failure = result {
                    XCTFail("Failed to create asset during reconfiguration")
                }
            }

            group.addTask {
                let result = await BMVideoCache.shared.preload(url: preloadURL, length: 1024)
                if case .failure = result {
                    XCTFail("Failed to preload during reconfiguration")
                }
            }
        }

        // 等待异步操作完成
        try await TestHelper.waitForAsyncOperations(timeout: 0.5)

        let cancelResult = await BMVideoCache.shared.cancelAllPreloads()
        if case .failure = cancelResult {
            XCTFail("Failed to cancel all preload tasks")
        }

        // 等待取消操作完成
        try await TestHelper.waitForAsyncOperations(timeout: 0.2)
    }

    func testStressTest() async throws {
        var testURLs: [URL] = []
        for i in 0..<100 {
            testURLs.append(URL(string: "https://example.com/stress-test-video\(i).mp4")!)
        }

        // 注册模拟视频
        TestHelper.registerMockVideos(for: testURLs)

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                let url = testURLs[i]
                group.addTask {
                    let result = await BMVideoCache.shared.asset(for: url)
                    if case .failure = result {
                        XCTFail("Failed to create asset for \(url)")
                    }
                }
            }

            for i in 20..<40 {
                let url = testURLs[i]
                group.addTask {
                    let result = await BMVideoCache.shared.preload(url: url, length: 1024)
                    if case .failure = result {
                        XCTFail("Failed to preload \(url)")
                    }
                }
            }

            group.addTask {
                let urls = Array(testURLs[40..<60])
                let result = await BMVideoCache.shared.preload(urls: urls, length: 1024)
                if case .failure = result {
                    XCTFail("Failed to batch preload")
                }
            }

            for i in 0..<10 {
                let url = testURLs[i]
                group.addTask {
                    let result = await BMVideoCache.shared.setCachePriority(for: url, priority: .high)
                    if case .failure = result {
                        XCTFail("Failed to set cache priority for \(url)")
                    }
                }
            }

            for i in 10..<20 {
                let url = testURLs[i]
                group.addTask {
                    let expirationDate = Date().addingTimeInterval(3600)
                    let result = await BMVideoCache.shared.setExpirationDate(for: url, date: expirationDate)
                    if case .failure = result {
                        XCTFail("Failed to set expiration date for \(url)")
                    }
                }
            }

            for _ in 0..<10 {
                group.addTask {
                    let result = await BMVideoCache.shared.getCacheStatistics()
                    if case .failure = result {
                        XCTFail("Failed to get cache statistics")
                    }
                }
            }

            group.addTask {
                let levels: [BMVideoCache.MemoryPressureLevel] = [.low, .medium, .high, .critical]
                for level in levels {
                    BMVideoCache.shared.setMemoryPressureLevel(level)
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
            }
        }

        // 等待异步操作完成
        try await TestHelper.waitForAsyncOperations(timeout: 0.5)

        let cancelResult = await BMVideoCache.shared.cancelAllPreloads()
        if case .failure = cancelResult {
            XCTFail("Failed to cancel all preload tasks")
        }

        // 等待取消操作完成
        try await TestHelper.waitForAsyncOperations(timeout: 0.2)
    }
}

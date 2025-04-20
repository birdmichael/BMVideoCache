import XCTest
@testable import BMVideoCache

final class BMCacheConfigurationTests: XCTestCase {
    
    func testDefaultConfiguration() throws {
        // 测试默认配置能否成功创建
        let config = try BMCacheConfiguration.defaultConfiguration()
        
        // 验证默认值
        XCTAssertEqual(config.maxCacheSizeInBytes, 500 * 1024 * 1024) // 默认 500MB
        XCTAssertEqual(config.preloadTaskTimeout, 60.0) 
        XCTAssertEqual(config.requestTimeoutInterval, 30.0)
        XCTAssertTrue(config.allowsCellularAccess)
        XCTAssertEqual(config.cacheFileExtension, "bmv")
        XCTAssertEqual(config.metadataFileExtension, "bmm")
        XCTAssertEqual(config.cacheSchemePrefix, "bmcache-")
        XCTAssertEqual(config.defaultExpirationInterval, 7 * 24 * 60 * 60) // 7天
        XCTAssertEqual(config.cleanupInterval, 60 * 60) // 1小时
        
        // 验证清理策略
        if case .leastRecentlyUsed = config.cleanupStrategy {
            // 成功，默认策略是 LRU
        } else {
            XCTFail("默认清理策略应为 LRU")
        }
    }
    
    func testCustomConfiguration() {
        // 测试自定义配置
        let testURL = FileManager.default.temporaryDirectory.appendingPathComponent("CustomCacheDir")
        let customConfig = BMCacheConfiguration(
            cacheDirectoryURL: testURL,
            maxCacheSizeInBytes: 200 * 1024 * 1024, // 200MB
            preloadTaskTimeout: 45.0,
            requestTimeoutInterval: 15.0,
            allowsCellularAccess: false,
            maxConcurrentDownloads: 5,
            customHTTPHeaderFields: ["User-Agent": "BMVideoCache-Test"],
            cacheKeyNamer: { url in return url.absoluteString.hash.description },
            cacheSchemePrefix: "test-cache-",
            defaultExpirationInterval: 2 * 24 * 60 * 60, // 2天
            cleanupInterval: 30 * 60, // 30分钟
            cleanupStrategy: .leastFrequentlyUsed,
            minimumDiskSpaceForCaching: 300 * 1024 * 1024 // 300MB
        )
        
        // 验证自定义值
        XCTAssertEqual(customConfig.cacheDirectoryURL, testURL)
        XCTAssertEqual(customConfig.maxCacheSizeInBytes, 200 * 1024 * 1024)
        XCTAssertEqual(customConfig.preloadTaskTimeout, 45.0)
        XCTAssertEqual(customConfig.requestTimeoutInterval, 15.0)
        XCTAssertFalse(customConfig.allowsCellularAccess)
        XCTAssertEqual(customConfig.maxConcurrentDownloads, 5)
        XCTAssertEqual(customConfig.customHTTPHeaderFields?["User-Agent"], "BMVideoCache-Test")
        XCTAssertEqual(customConfig.cacheSchemePrefix, "test-cache-")
        XCTAssertEqual(customConfig.defaultExpirationInterval, 2 * 24 * 60 * 60)
        XCTAssertEqual(customConfig.cleanupInterval, 30 * 60)
        XCTAssertEqual(customConfig.minimumDiskSpaceForCaching, 300 * 1024 * 1024)
        
        // 验证清理策略
        if case .leastFrequentlyUsed = customConfig.cleanupStrategy {
            // 成功，策略已正确设置
        } else {
            XCTFail("清理策略应为 LFU")
        }
        
        // 测试 cacheKeyNamer
        let testURL1 = URL(string: "https://example.com/video.mp4")!
        let key1 = customConfig.cacheKeyNamer!(testURL1)
        XCTAssertEqual(key1, testURL1.absoluteString.hash.description)
    }
    
    func testCacheURLGeneration() {
        let testURL = FileManager.default.temporaryDirectory.appendingPathComponent("URLTest")
        let config = BMCacheConfiguration(
            cacheDirectoryURL: testURL,
            maxCacheSizeInBytes: 100 * 1024 * 1024
        )
        
        // 测试缓存文件URL生成
        let key = "test-key-123"
        let cacheFileURL = config.cacheFileURL(for: key)
        
        XCTAssertEqual(cacheFileURL, testURL.appendingPathComponent("\(key).bmv"))
        
        // 测试元数据文件URL生成
        let metadataFileURL = config.metadataFileURL(for: key)
        let expectedMetadataURL = testURL.appendingPathComponent("Metadata").appendingPathComponent("\(key).bmm")
        
        XCTAssertEqual(metadataFileURL, expectedMetadataURL)
    }
    
    func testCleanupStrategyEquality() {
        // 测试清理策略相等判断
        XCTAssertEqual(BMCacheConfiguration.CacheCleanupStrategy.leastRecentlyUsed, .leastRecentlyUsed)
        XCTAssertEqual(BMCacheConfiguration.CacheCleanupStrategy.leastFrequentlyUsed, .leastFrequentlyUsed)
        XCTAssertEqual(BMCacheConfiguration.CacheCleanupStrategy.firstInFirstOut, .firstInFirstOut)
        XCTAssertEqual(BMCacheConfiguration.CacheCleanupStrategy.expired, .expired)
        XCTAssertEqual(BMCacheConfiguration.CacheCleanupStrategy.priorityBased, .priorityBased)
        
        // 测试自定义策略相等性
        let comparator: (URL, URL) -> Bool = { _, _ in return true }
        let custom1 = BMCacheConfiguration.CacheCleanupStrategy.custom(identifier: "test", comparator: comparator)
        let custom2 = BMCacheConfiguration.CacheCleanupStrategy.custom(identifier: "test", comparator: comparator)
        let custom3 = BMCacheConfiguration.CacheCleanupStrategy.custom(identifier: "other", comparator: comparator)
        
        XCTAssertEqual(custom1, custom2) // 相同标识符的自定义策略应相等
        XCTAssertNotEqual(custom1, custom3) // 不同标识符的自定义策略不应相等
        XCTAssertNotEqual(custom1, .leastRecentlyUsed) // 不同类型的策略不应相等
    }
}

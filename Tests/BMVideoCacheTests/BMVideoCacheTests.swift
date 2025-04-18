import XCTest
@testable import BMVideoCache

final class BMVideoCacheTests: XCTestCase {
    func testExample() async throws {
        await BMVideoCache.shared.ensureInitialized()

        let initialSizeResult = await BMVideoCache.shared.calculateCurrentCacheSize()
        guard case .success(let initialSize) = initialSizeResult else {
            XCTFail("获取缓存大小失败")
            return
        }
        XCTAssertEqual(initialSize, 0, "初始缓存大小应该为0")

        let clearResult = await BMVideoCache.shared.clearCache()
        guard case .success = clearResult else {
            XCTFail("清除缓存失败")
            return
        }
    }

    func testAssetCreation() async throws {
        await BMVideoCache.shared.ensureInitialized()

        let testURL = URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4")!

        let assetResult = await BMVideoCache.shared.asset(for: testURL)

        guard case .success(let asset) = assetResult else {
            XCTFail("创建资源失败")
            return
        }

        XCTAssertTrue(asset.url.absoluteString.contains("bmcache"), "资源URL应包含bmcache前缀")

        let originalURLResult = BMVideoCache.shared.originalURL(from: asset.url)
        guard case .success(let originalURL) = originalURLResult else {
            XCTFail("获取原始URL失败")
            return
        }
        XCTAssertEqual(originalURL.absoluteString, testURL.absoluteString, "从缓存URL获取的原始URL应与测试URL相同")
    }

    func testReconfiguration() async throws {
        await BMVideoCache.shared.ensureInitialized()

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("BMVideoCacheTest")
        let customConfig = BMCacheConfiguration(
            cacheDirectoryURL: tempDir,
            maxCacheSizeInBytes: 1024 * 1024 * 10
        )

        let reconfigureResult = await BMVideoCache.shared.reconfigure(with: customConfig)
        if case .failure(let error) = reconfigureResult {
            XCTFail("Reconfiguration failed with error: \(error)")
        }

        let sizeResult = await BMVideoCache.shared.calculateCurrentCacheSize()
        guard case .success(let size) = sizeResult else {
            XCTFail("获取缓存大小失败")
            return
        }
        XCTAssertEqual(size, 0, "重新配置后缓存大小应该为0")

        let finalClearResult = await BMVideoCache.shared.clearCache()
        guard case .success = finalClearResult else {
            XCTFail("清除缓存失败")
            return
        }
    }
}

import XCTest
@testable import BMVideoCache

final class BMHLSTests: XCTestCase {

    override func setUp() async throws {
        _ = await BMVideoCache.shared.clearCache()
        TestHelper.setupMockURLSession()
    }

    override func tearDown() async throws {
        _ = await BMVideoCache.shared.clearCache()
        TestHelper.tearDownMockURLSession()
    }

    func testHLSAssetCreation() async throws {
        // 创建模拟的m3u8内容
        let m3u8Content = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:10
        #EXT-X-MEDIA-SEQUENCE:0
        #EXTINF:10.0,
        segment1.ts
        #EXTINF:10.0,
        segment2.ts
        #EXTINF:10.0,
        segment3.ts
        #EXT-X-ENDLIST
        """

        // 注册模拟的m3u8响应
        let testURL = URL(string: "https://example.com/test.m3u8")!
        let mockData = Data(m3u8Content.utf8)
        MockURLProtocol.registerMockResponse(for: testURL, data: mockData, contentType: "application/vnd.apple.mpegurl")

        // 注册模拟的分段响应
        let baseURL = testURL.deletingLastPathComponent()
        let segmentURLs = [
            baseURL.appendingPathComponent("segment1.ts"),
            baseURL.appendingPathComponent("segment2.ts"),
            baseURL.appendingPathComponent("segment3.ts")
        ]

        for segmentURL in segmentURLs {
            let segmentData = Data(repeating: 0, count: 1024 * 10) // 10KB的模拟数据
            MockURLProtocol.registerMockResponse(for: segmentURL, data: segmentData, contentType: "video/mp2t")
        }

        // 创建资产
        let assetResult = await BMVideoCache.shared.asset(for: testURL)

        guard case .success(let asset) = assetResult else {
            XCTFail("创建HLS资产失败")
            return
        }

        XCTAssertTrue(asset.url.absoluteString.contains("bmcache"), "资产URL应包含bmcache前缀")

        // 验证原始URL恢复
        let originalURLResult = BMVideoCache.shared.originalURL(from: asset.url)
        guard case .success(let originalURL) = originalURLResult else {
            XCTFail("获取原始URL失败")
            return
        }

        XCTAssertEqual(originalURL.absoluteString, testURL.absoluteString, "从缓存URL获取的原始URL应与测试URL相同")
    }

    func testHLSPreload() async throws {
        // 创建模拟的m3u8内容
        let m3u8Content = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:10
        #EXT-X-MEDIA-SEQUENCE:0
        #EXTINF:10.0,
        segment1.ts
        #EXTINF:10.0,
        segment2.ts
        #EXT-X-ENDLIST
        """

        // 注册模拟的m3u8响应
        let testURL = URL(string: "https://example.com/preload.m3u8")!
        let mockData = Data(m3u8Content.utf8)
        MockURLProtocol.registerMockResponse(for: testURL, data: mockData, contentType: "application/vnd.apple.mpegurl")

        // 注册模拟的分段响应
        let baseURL = testURL.deletingLastPathComponent()
        let segmentURLs = [
            baseURL.appendingPathComponent("segment1.ts"),
            baseURL.appendingPathComponent("segment2.ts")
        ]

        for segmentURL in segmentURLs {
            let segmentData = Data(repeating: 0, count: 1024 * 10) // 10KB的模拟数据
            MockURLProtocol.registerMockResponse(for: segmentURL, data: segmentData, contentType: "video/mp2t")
        }

        // 预加载HLS内容
        let preloadResult = await BMVideoCache.shared.preload(url: testURL)

        guard case .success(let taskId) = preloadResult else {
            XCTFail("预加载HLS内容失败")
            return
        }

        // 验证任务ID
        XCTAssertNotNil(taskId, "预加载任务ID不应为空")

        // 验证预加载状态
        let statusResult = await BMVideoCache.shared.getPreloadStatus(taskId: taskId)
        guard case .success(let status) = statusResult else {
            XCTFail("获取预加载状态失败")
            return
        }

        // 预加载应该已启动
        XCTAssertTrue(status == "running" || status == "completed", "预加载应该已启动或已完成")
    }

    func testHLSCacheAndReuse() async throws {
        // 创建模拟的m3u8内容
        let m3u8Content = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:10
        #EXT-X-MEDIA-SEQUENCE:0
        #EXTINF:10.0,
        segment1.ts
        #EXTINF:10.0,
        segment2.ts
        #EXT-X-ENDLIST
        """

        // 注册模拟的m3u8响应
        let testURL = URL(string: "https://example.com/cache_test.m3u8")!
        let mockData = Data(m3u8Content.utf8)
        MockURLProtocol.registerMockResponse(for: testURL, data: mockData, contentType: "application/vnd.apple.mpegurl")

        // 注册模拟的分段响应
        let baseURL = testURL.deletingLastPathComponent()
        let segmentURLs = [
            baseURL.appendingPathComponent("segment1.ts"),
            baseURL.appendingPathComponent("segment2.ts")
        ]

        for segmentURL in segmentURLs {
            let segmentData = Data(repeating: 0, count: 1024 * 10) // 10KB的模拟数据
            MockURLProtocol.registerMockResponse(for: segmentURL, data: segmentData, contentType: "video/mp2t")
        }

        // 第一次创建资产，应该触发缓存
        let firstAssetResult = await BMVideoCache.shared.asset(for: testURL)
        guard case .success(let firstAsset) = firstAssetResult else {
            XCTFail("第一次创建HLS资产失败")
            return
        }

        // 等待缓存完成
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2秒

        // 重置模拟响应，模拟网络不可用
        MockURLProtocol.reset()

        // 第二次创建资产，应该使用缓存
        let secondAssetResult = await BMVideoCache.shared.asset(for: testURL)
        guard case .success(let secondAsset) = secondAssetResult else {
            XCTFail("第二次创建HLS资产失败，说明缓存不生效")
            return
        }

        // 验证两次创建的资产URL相同
        XCTAssertEqual(firstAsset.url.absoluteString, secondAsset.url.absoluteString, "两次创建的资产URL应相同")
    }
}

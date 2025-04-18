import Foundation
import XCTest
@testable import BMVideoCache

class TestHelper {
    static func setupMockURLSession() {
        URLProtocol.registerClass(MockURLProtocol.self)
    }

    static func tearDownMockURLSession() {
        URLProtocol.unregisterClass(MockURLProtocol.self)
        MockURLProtocol.reset()
    }

    static func registerMockVideo(for url: URL, size: Int = 1024 * 1024) {
        // 创建模拟的视频数据
        let mockData = Data(repeating: 0, count: size)
        MockURLProtocol.registerMockResponse(for: url, data: mockData)
    }

    static func registerMockVideos(for urls: [URL], size: Int = 1024 * 1024) {
        for url in urls {
            registerMockVideo(for: url, size: size)
        }
    }

    static func waitForAsyncOperations(timeout: TimeInterval = 1.0) async throws {
        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
    }

    static func setupCacheForTest(url: URL, size: Int = 1024 * 1024) async {
        // 注册模拟视频
        registerMockVideo(for: url, size: size)

        // 直接添加到缓存
        await DirectCacheHelper.directlyAddItemToCache(for: url, size: size)
    }

    static func setupCacheForTests(urls: [URL], size: Int = 1024 * 1024) async {
        // 注册模拟视频
        registerMockVideos(for: urls, size: size)

        // 直接添加到缓存
        for url in urls {
            await DirectCacheHelper.directlyAddItemToCache(for: url, size: size)
        }
    }

    static func setupCacheWithPriorities(
        lowURLs: [URL] = [],
        normalURLs: [URL] = [],
        highURLs: [URL] = [],
        permanentURLs: [URL] = [],
        size: Int = 1024 * 1024
    ) async {
        // 注册所有模拟视频
        registerMockVideos(for: lowURLs + normalURLs + highURLs + permanentURLs, size: size)

        // 直接添加到缓存并设置优先级
        await DirectCacheHelper.directlyAddItemsToCacheWithPriorities(
            lowURLs: lowURLs,
            normalURLs: normalURLs,
            highURLs: highURLs,
            permanentURLs: permanentURLs,
            size: size
        )
    }

    static func setupExpiredCache(url: URL, size: Int = 1024 * 1024) async {
        // 注册模拟视频
        registerMockVideo(for: url, size: size)

        // 直接添加过期项到缓存
        await DirectCacheHelper.directlyAddExpiredItemToCache(for: url, size: size)
    }
}

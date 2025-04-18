import XCTest
@testable import BMVideoCache
import AVKit

final class BMVideoURLTests: XCTestCase {
    let testVideos = [
        "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4",
        "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ElephantsDream.mp4",
        "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerBlazes.mp4",
        "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerEscapes.mp4",
        "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerFun.mp4",
        "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerJoyrides.mp4"
    ]

    override func setUp() async throws {
        _ = await BMVideoCache.shared.clearCache()
    }

    override func tearDown() async throws {
        _ = await BMVideoCache.shared.clearCache()
    }

    func testAssetCreation() async throws {
        for urlString in testVideos {
            let url = URL(string: urlString)!
            let result = await BMVideoCache.shared.asset(for: url)

            switch result {
            case .success(let asset):
                XCTAssertNotNil(asset)
                XCTAssertTrue(asset.url.absoluteString.contains("bmcache"))
            case .failure(let error):
                XCTFail("Failed to create asset for \(urlString): \(error)")
            }
        }
    }

    func testPreloadAndCacheStatistics() async throws {
        let url = URL(string: testVideos[0])!
        let preloadResult = await BMVideoCache.shared.preload(url: url, length: 1024 * 1024)

        switch preloadResult {
        case .success(let taskId):
            XCTAssertNotNil(taskId)

            var status = ""
            for _ in 0..<10 {
                let statusResult = await BMVideoCache.shared.getPreloadStatus(taskId: taskId)
                if case .success(let currentStatus) = statusResult {
                    status = currentStatus
                    if status == "completed" || status.contains("failed") {
                        break
                    }
                }
                try await Task.sleep(nanoseconds: 500_000_000)
            }

            let statsResult = await BMVideoCache.shared.getCacheStatistics()
            if case .success(let stats) = statsResult {
                XCTAssertGreaterThanOrEqual(stats.totalItemCount, 0)
                XCTAssertGreaterThanOrEqual(stats.totalCacheSize, 0)
            } else {
                XCTFail("Failed to get cache statistics")
            }

        case .failure(let error):
            XCTFail("Failed to preload \(url): \(error)")
        }
    }

    func testBatchPreload() async throws {
        let urls = testVideos.prefix(3).map { URL(string: $0)! }
        let preloadResult = await BMVideoCache.shared.preload(urls: urls, length: 512 * 1024)

        switch preloadResult {
        case .success(let taskIds):
            XCTAssertEqual(taskIds.count, 3)

            try await Task.sleep(nanoseconds: 1_000_000_000)

            let cancelResult = await BMVideoCache.shared.cancelAllPreloads()
            if case .failure(let error) = cancelResult {
                XCTFail("Failed to cancel preloads: \(error)")
            }

            let statsResult = await BMVideoCache.shared.getPreloadStatistics()
            if case .success(let stats) = statsResult {
                XCTAssertGreaterThanOrEqual(stats.created, 3)
            } else {
                XCTFail("Failed to get preload statistics")
            }

        case .failure(let error):
            XCTFail("Failed to batch preload: \(error)")
        }
    }

    func testCachePriorityAndExpiration() async throws {
        let url1 = URL(string: testVideos[0])!
        let url2 = URL(string: testVideos[1])!

        let asset1Result = await BMVideoCache.shared.asset(for: url1)
        let asset2Result = await BMVideoCache.shared.asset(for: url2)

        guard case .success(_) = asset1Result, case .success(_) = asset2Result else {
            XCTFail("Failed to create assets")
            return
        }

        _ = await BMVideoCache.shared.setCachePriority(for: url1, priority: .high)
        _ = await BMVideoCache.shared.setCachePriority(for: url2, priority: .low)

        let futureDate = Date().addingTimeInterval(3600)
        _ = await BMVideoCache.shared.setExpirationDate(for: url2, date: futureDate)

        BMVideoCache.shared.setMemoryPressureLevel(.medium)

        try await Task.sleep(nanoseconds: 500_000_000)

        BMVideoCache.shared.setMemoryPressureLevel(.low)
    }

    func testConcurrentOperations() async throws {
        await withTaskGroup(of: Void.self) { group in
            for urlString in testVideos {
                group.addTask {
                    let url = URL(string: urlString)!
                    _ = await BMVideoCache.shared.asset(for: url)
                }
            }

            group.addTask {
                let url = URL(string: self.testVideos[0])!
                _ = await BMVideoCache.shared.preload(url: url, length: 256 * 1024)
            }

            group.addTask {
                _ = await BMVideoCache.shared.getCacheStatistics()
            }

            group.addTask {
                let url = URL(string: self.testVideos[1])!
                _ = await BMVideoCache.shared.setCachePriority(for: url, priority: .high)
            }
        }

        XCTAssertTrue(true)
    }

    func testReconfiguration() async throws {
        let url = URL(string: testVideos[0])!
        let assetResult = await BMVideoCache.shared.asset(for: url)
        guard case .success(_) = assetResult else {
            XCTFail("Failed to create asset")
            return
        }

        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("BMVideoCacheTest")
        let newConfig = BMCacheConfiguration(
            cacheDirectoryURL: cacheDir,
            maxCacheSizeInBytes: 50 * 1024 * 1024
        )

        let reconfigResult = await BMVideoCache.shared.reconfigure(with: newConfig, preserveExistingCache: false)

        switch reconfigResult {
        case .success:
            let statsResult = await BMVideoCache.shared.getCacheStatistics()
            if case .success(_) = statsResult {
            } else {
                XCTFail("Failed to get cache statistics after reconfiguration")
            }
        case .failure(let error):
            XCTFail("Failed to reconfigure: \(error)")
        }
    }

    func testPerformance() async throws {
        measure {
            let expectation = XCTestExpectation(description: "Asset creation")
            Task {
                let url = URL(string: self.testVideos[0])!
                _ = await BMVideoCache.shared.asset(for: url)
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 5.0)
        }
    }
}

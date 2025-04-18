import XCTest
@testable import BMVideoCache

final class BMPerformanceTests: XCTestCase {

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



    func testAssetCreationPerformance() throws {
        let testURL = URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4")!

        measure {
            let expectation = XCTestExpectation(description: "Asset creation")

            Task {
                for _ in 0..<100 {
                    let result = await BMVideoCache.shared.asset(for: testURL)
                    if case .failure = result {
                        XCTFail("Failed to create asset")
                    }
                }
                expectation.fulfill()
            }

            wait(for: [expectation], timeout: 10.0)
        }
    }

    func testPreloadPerformance() throws {
        let testVideos = [
            "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4",
            "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ElephantsDream.mp4",
            "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerBlazes.mp4",
            "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerEscapes.mp4",
            "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerFun.mp4",
            "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerJoyrides.mp4"
        ]

        var testURLs: [URL] = []
        for _ in 0..<10 {
            for urlString in testVideos {
                testURLs.append(URL(string: urlString)!)
            }
        }

        measure {
            let expectation = XCTestExpectation(description: "Batch preload")

            Task {
                let result = await BMVideoCache.shared.preload(urls: testURLs, length: 1024)
                if case .failure = result {
                    XCTFail("Failed to start batch preload")
                }

                let cancelResult = await BMVideoCache.shared.cancelAllPreloads()
                if case .failure = cancelResult {
                    XCTFail("Failed to cancel all preload tasks")
                }

                expectation.fulfill()
            }

            wait(for: [expectation], timeout: 10.0)
        }
    }

    func testCacheStatisticsPerformance() throws {
        measure {
            let expectation = XCTestExpectation(description: "Get cache statistics")

            Task {
                for _ in 0..<100 {
                    let result = await BMVideoCache.shared.getCacheStatistics()
                    if case .failure = result {
                        XCTFail("Failed to get cache statistics")
                    }
                }
                expectation.fulfill()
            }

            wait(for: [expectation], timeout: 10.0)
        }
    }

    func testConcurrentAssetCreation() throws {
        let testVideos = [
            "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4",
            "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ElephantsDream.mp4",
            "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerBlazes.mp4",
            "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerEscapes.mp4",
            "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerFun.mp4",
            "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerJoyrides.mp4"
        ]

        var testURLs: [URL] = []
        for _ in 0..<10 {
            for urlString in testVideos {
                testURLs.append(URL(string: urlString)!)
            }
        }

        measure {
            let expectation = XCTestExpectation(description: "Concurrent asset creation")

            Task {
                await withTaskGroup(of: Void.self) { group in
                    for url in testURLs {
                        group.addTask {
                            let result = await BMVideoCache.shared.asset(for: url)
                            if case .failure = result {
                                XCTFail("Failed to create asset")
                            }
                        }
                    }
                }
                expectation.fulfill()
            }

            wait(for: [expectation], timeout: 10.0)
        }
    }

    func testMemoryPressureResponse() throws {
        let testURL = URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4")!

        measure {
            let expectation = XCTestExpectation(description: "Memory pressure response")

            Task {
                let assetResult = await BMVideoCache.shared.asset(for: testURL)
                if case .failure = assetResult {
                    XCTFail("Failed to create asset")
                }

                BMVideoCache.shared.setMemoryPressureLevel(.critical)

                try await Task.sleep(nanoseconds: 100_000_000)

                expectation.fulfill()
            }

            wait(for: [expectation], timeout: 10.0)
        }
    }



    func testConcurrentOperations() throws {
        measure {
            let expectation = XCTestExpectation(description: "Concurrent operations")

            Task {
                await withTaskGroup(of: Void.self) { group in
                    let testVideos = [
                        "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4",
                        "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ElephantsDream.mp4",
                        "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerBlazes.mp4",
                        "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerEscapes.mp4",
                        "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerFun.mp4",
                        "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerJoyrides.mp4"
                    ]

                    for urlString in testVideos {
                        let url = URL(string: urlString)!
                        group.addTask {
                            let result = await BMVideoCache.shared.asset(for: url)
                            if case .failure = result {
                                XCTFail("Failed to create asset")
                            }
                        }
                    }

                    group.addTask {
                        let urls = testVideos.map { URL(string: $0)! }
                        let result = await BMVideoCache.shared.preload(urls: urls, length: 1024)
                        if case .failure = result {
                            XCTFail("Failed to start batch preload")
                        }
                    }

                    group.addTask {
                        for _ in 0..<10 {
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

                let cancelResult = await BMVideoCache.shared.cancelAllPreloads()
                if case .failure = cancelResult {
                    XCTFail("Failed to cancel all preload tasks")
                }

                expectation.fulfill()
            }

            wait(for: [expectation], timeout: 20.0)
        }
    }
}

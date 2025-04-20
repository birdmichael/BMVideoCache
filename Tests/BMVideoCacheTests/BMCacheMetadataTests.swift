import XCTest
@testable import BMVideoCache

final class BMCacheMetadataTests: XCTestCase {
    
    // 测试目录URL，用于存储临时文件
    var testDirectoryURL: URL?
    
    override func setUp() async throws {
        // 创建临时目录
        let tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BMCacheMetadataTests_\(UUID().uuidString)")
        
        try FileManager.default.createDirectory(
            at: tempDirectoryURL,
            withIntermediateDirectories: true
        )
        
        self.testDirectoryURL = tempDirectoryURL
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
    
    func testMetadataInitialization() {
        // 测试元数据初始化
        let key = "test-cache-key"
        let url = URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4")!
        let metadata = BMCacheMetadata(cacheKey: key, originalURL: url)
        
        XCTAssertEqual(metadata.cacheKey, key)
        XCTAssertEqual(metadata.originalURL, url)
        XCTAssertNil(metadata.contentInfo)
        XCTAssertTrue(metadata.cachedRanges.isEmpty)
        XCTAssertFalse(metadata.isComplete)
        XCTAssertEqual(metadata.totalCachedSize, 0)
        XCTAssertEqual(metadata.priority, .normal)
        XCTAssertEqual(metadata.accessCount, 0)
    }
    
    func testMetadataWithContentInfo() {
        // 测试带内容信息的元数据
        let key = "test-content-key"
        let url = URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ElephantsDream.mp4")!
        let contentInfo = BMContentInfo(
            contentType: "video/mp4",
            contentLength: 1024 * 1024, // 1MB
            isByteRangeAccessSupported: true
        )
        
        let metadata = BMCacheMetadata(cacheKey: key, originalURL: url, contentInfo: contentInfo)
        
        XCTAssertEqual(metadata.cacheKey, key)
        XCTAssertEqual(metadata.originalURL, url)
        XCTAssertEqual(metadata.contentInfo, contentInfo)
        XCTAssertTrue(metadata.cachedRanges.isEmpty)
        XCTAssertFalse(metadata.isComplete)
        XCTAssertEqual(metadata.totalCachedSize, 0)
    }
    
    func testAddCachedRange() {
        // 测试添加缓存范围
        let key = "test-range-key"
        let url = URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerBlazes.mp4")!
        var metadata = BMCacheMetadata(cacheKey: key, originalURL: url)
        
        // 添加一个范围
        let range1: ClosedRange<Int64> = 0...499
        metadata.addCachedRange(range1)
        
        XCTAssertEqual(metadata.cachedRanges.count, 1)
        XCTAssertEqual(metadata.cachedRanges[0], range1)
        XCTAssertEqual(metadata.totalCachedSize, 500)
        
        // 添加第二个范围
        let range2: ClosedRange<Int64> = 600...999
        metadata.addCachedRange(range2)
        
        XCTAssertEqual(metadata.cachedRanges.count, 2)
        XCTAssertEqual(metadata.totalCachedSize, 900) // 500 + 400
        
        // 添加第三个范围，这个范围与第二个范围相连
        let range3: ClosedRange<Int64> = 1000...1499
        metadata.addCachedRange(range3)
        
        // 由于范围2和范围3相连，它们应该被合并
        XCTAssertEqual(metadata.cachedRanges.count, 2)
        XCTAssertEqual(metadata.cachedRanges[0], 0...499)
        XCTAssertEqual(metadata.cachedRanges[1], 600...1499)
        XCTAssertEqual(metadata.totalCachedSize, 1400) // 500 + 900
    }
    
    func testMergeOverlappingRanges() {
        // 测试合并重叠范围
        let ranges: [ClosedRange<Int64>] = [
            10...20,
            5...15,
            25...30,
            18...27
        ]
        
        let merged = BMCacheMetadata.mergeRanges(ranges)
        
        // 所有范围应该合并为一个范围：5...30
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0], Int64(5)...Int64(30))
    }
    
    func testMergeAdjacentRanges() {
        // 测试合并相邻范围
        let ranges: [ClosedRange<Int64>] = [
            1...5,
            6...10,
            11...15
        ]
        
        let merged = BMCacheMetadata.mergeRanges(ranges)
        
        // 相邻范围应合并为一个范围：1...15
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0], Int64(1)...Int64(15))
    }
    
    func testMergeDisjointRanges() {
        // 测试合并不相邻的范围
        let ranges: [ClosedRange<Int64>] = [
            1...5,
            10...15,
            20...25
        ]
        
        let merged = BMCacheMetadata.mergeRanges(ranges)
        
        // 不相邻的范围应保持分开
        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged[0], Int64(1)...Int64(5))
        XCTAssertEqual(merged[1], Int64(10)...Int64(15))
        XCTAssertEqual(merged[2], Int64(20)...Int64(25))
    }
    
    func testContentInfoHLSDetection() {
        // 测试HLS内容类型检测
        
        // 测试MP4类型（非HLS）
        let mp4Info = BMContentInfo(
            contentType: "video/mp4",
            contentLength: 1024,
            isByteRangeAccessSupported: true
        )
        XCTAssertFalse(mp4Info.isHLSContent)
        
        // 测试HLS类型 1
        let hlsInfo1 = BMContentInfo(
            contentType: "application/vnd.apple.mpegurl",
            contentLength: 1024,
            isByteRangeAccessSupported: true
        )
        XCTAssertTrue(hlsInfo1.isHLSContent)
        
        // 测试HLS类型 2
        let hlsInfo2 = BMContentInfo(
            contentType: "application/x-mpegurl",
            contentLength: 1024,
            isByteRangeAccessSupported: true
        )
        XCTAssertTrue(hlsInfo2.isHLSContent)
        
        // 测试HLS类型 3
        let hlsInfo3 = BMContentInfo(
            contentType: "audio/mpegurl",
            contentLength: 1024,
            isByteRangeAccessSupported: true
        )
        XCTAssertTrue(hlsInfo3.isHLSContent)
    }
    
    func testCachePriorityComparison() {
        // 测试缓存优先级比较
        XCTAssertTrue(CachePriority.low < CachePriority.normal)
        XCTAssertTrue(CachePriority.normal < CachePriority.high)
        XCTAssertTrue(CachePriority.high < CachePriority.permanent)
        
        XCTAssertFalse(CachePriority.normal < CachePriority.low)
        XCTAssertFalse(CachePriority.high < CachePriority.normal)
        XCTAssertFalse(CachePriority.permanent < CachePriority.high)
    }
}

import XCTest
@testable import BMVideoCache

final class BMRangeMergeTests: XCTestCase {


    private func createTestManager() async -> BMCacheManager {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("BMRangeMergeTest")
        let config = BMCacheConfiguration(
            cacheDirectoryURL: tempDir,
            maxCacheSizeInBytes: 1024 * 1024
        )
        return await BMCacheManager.create(configuration: config)
    }


    func testEmptyRanges() async throws {
        let manager = await createTestManager()

        let result = await manager.merge(ranges: [])

        XCTAssertEqual(result.count, 0)
    }


    func testSingleRange() async throws {
        let manager = await createTestManager()
        let ranges = [Int64(10)...Int64(20)]

        let result = await manager.merge(ranges: ranges)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.lowerBound, 10)
        XCTAssertEqual(result.first?.upperBound, 20)
    }


    func testNonOverlappingRanges() async throws {
        let manager = await createTestManager()
        let ranges = [Int64(10)...Int64(20), Int64(30)...Int64(40), Int64(50)...Int64(60)]

        let result = await manager.merge(ranges: ranges)

        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].lowerBound, 10)
        XCTAssertEqual(result[0].upperBound, 20)
        XCTAssertEqual(result[1].lowerBound, 30)
        XCTAssertEqual(result[1].upperBound, 40)
        XCTAssertEqual(result[2].lowerBound, 50)
        XCTAssertEqual(result[2].upperBound, 60)
    }


    func testOverlappingRanges() async throws {
        let manager = await createTestManager()
        let ranges = [Int64(10)...Int64(30), Int64(20)...Int64(40)]

        let result = await manager.merge(ranges: ranges)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.lowerBound, 10)
        XCTAssertEqual(result.first?.upperBound, 40)
    }


    func testAdjacentRanges() async throws {
        let manager = await createTestManager()
        let ranges = [Int64(10)...Int64(20), Int64(21)...Int64(30)]

        let result = await manager.merge(ranges: ranges)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.lowerBound, 10)
        XCTAssertEqual(result.first?.upperBound, 30)
    }


    func testContainedRanges() async throws {
        let manager = await createTestManager()
        let ranges = [Int64(10)...Int64(40), Int64(15)...Int64(30)]

        let result = await manager.merge(ranges: ranges)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.lowerBound, 10)
        XCTAssertEqual(result.first?.upperBound, 40)
    }


    func testComplexRanges() async throws {
        let manager = await createTestManager()
        let ranges = [Int64(10)...Int64(20), Int64(30)...Int64(40), Int64(15)...Int64(35), Int64(50)...Int64(60), Int64(59)...Int64(70)]

        let result = await manager.merge(ranges: ranges)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].lowerBound, 10)
        XCTAssertEqual(result[0].upperBound, 40)
        XCTAssertEqual(result[1].lowerBound, 50)
        XCTAssertEqual(result[1].upperBound, 70)
    }
}

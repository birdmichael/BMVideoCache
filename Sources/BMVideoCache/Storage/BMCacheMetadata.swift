import Foundation
public struct BMCacheMetadata: Codable, Equatable {
    public let cacheKey: String
    let originalURL: URL
    var contentInfo: BMContentInfo?
    var cachedRanges: [ClosedRange<Int64>] = []
    var lastAccessDate: Date = Date()
    var expirationDate: Date?
    var priority: CachePriority = .normal
    var accessCount: Int = 0
    var isComplete: Bool = false
    var totalCachedSize: UInt64 = 0

    init(cacheKey: String, originalURL: URL, contentInfo: BMContentInfo? = nil) {
        self.cacheKey = cacheKey
        self.originalURL = originalURL
        self.contentInfo = contentInfo
    }

    var accurateFileSize: Int64? {
        return contentInfo?.contentLength
    }
    var estimatedFileSizeBasedOnRanges: Int64 {
        cachedRanges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound + 1) }
    }
    func cachedSize() -> UInt64 {
        return totalCachedSize
    }
    mutating func addCachedRange(_ range: ClosedRange<Int64>) {
        let updatedRanges = Self.mergeRanges(cachedRanges + [range])
        self.cachedRanges = updatedRanges
        self.totalCachedSize = updatedRanges.reduce(0) { $0 + UInt64($1.upperBound - $1.lowerBound + 1) }
        self.lastAccessDate = Date()
        if let totalLength = contentInfo?.contentLength, totalLength > 0 {
            self.isComplete = self.totalCachedSize >= UInt64(totalLength)
        }
    }

    // MARK: - Range Merging Logic (Public Static Utility)
    public static func mergeRanges(_ ranges: [ClosedRange<Int64>]) -> [ClosedRange<Int64>] {
        guard !ranges.isEmpty else { return [] }

        let sortedRanges = ranges.sorted { $0.lowerBound < $1.lowerBound }

        guard var currentRange = sortedRanges.first else { return [] }

        var merged = [ClosedRange<Int64>]()
        for nextRange in sortedRanges.dropFirst() {
            if nextRange.lowerBound <= currentRange.upperBound + 1 { 
                currentRange = ClosedRange(uncheckedBounds: (lower: currentRange.lowerBound, upper: max(currentRange.upperBound, nextRange.upperBound)))
            } else {
                merged.append(currentRange)
                currentRange = nextRange
            }
        }
        merged.append(currentRange)
        return merged
    }
}
public enum CachePriority: Int, Codable, Comparable {
    case low = 0
    case normal = 1
    case high = 2
    case permanent = 3
    public static func < (lhs: CachePriority, rhs: CachePriority) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}
public struct BMContentInfo: Codable, Equatable {
    var contentType: String
    var contentLength: Int64
    var isByteRangeAccessSupported: Bool

    var isHLSContent: Bool {
        return contentType.contains("application/vnd.apple.mpegurl") ||
               contentType.contains("application/x-mpegurl") ||
               contentType.contains("audio/mpegurl") ||
               contentType.contains("audio/x-mpegurl")
    }
}

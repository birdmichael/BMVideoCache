import Foundation
internal struct BMCacheMetadata: Codable, Equatable {
    let originalURL: URL
    var contentInfo: BMContentInfo?
    var cachedRanges: [ClosedRange<Int64>] = []
    var lastAccessDate: Date = Date()
    var expirationDate: Date?
    var priority: CachePriority = .normal
    var accessCount: Int = 0
    var accurateFileSize: Int64? {
        return contentInfo?.contentLength
    }
    var estimatedFileSizeBasedOnRanges: Int64 {
        cachedRanges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound + 1) }
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
internal struct BMContentInfo: Codable, Equatable {
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

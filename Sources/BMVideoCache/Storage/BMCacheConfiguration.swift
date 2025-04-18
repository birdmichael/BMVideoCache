import Foundation
public struct BMCacheConfiguration {
    public let cacheDirectoryURL: URL
    public let maxCacheSizeInBytes: UInt64
    public let cacheFileExtension: String = "bmv"
    public let metadataFileExtension: String = "bmm"
    public let cacheSchemePrefix: String
    public let preloadTaskTimeout: TimeInterval?
    public let requestTimeoutInterval: TimeInterval
    public let allowsCellularAccess: Bool
    public let maxConcurrentDownloads: Int
    public let customHTTPHeaderFields: [String: String]?
    public let cacheKeyNamer: ((URL) -> String)?
    public let defaultExpirationInterval: TimeInterval?
    public let cleanupInterval: TimeInterval
    public let cleanupStrategy: CacheCleanupStrategy
    public let minimumDiskSpaceForCaching: UInt64
    internal static func defaultConfiguration() throws -> BMCacheConfiguration {
        let cacheBaseDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let cacheDirectoryURL = cacheBaseDirectory.appendingPathComponent("BMVideoCache")
        if !FileManager.default.fileExists(atPath: cacheDirectoryURL.path) {
            try FileManager.default.createDirectory(at: cacheDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        }
        let defaultCacheSize: UInt64 = 500 * 1024 * 1024
        let defaultTimeout: TimeInterval = 30.0
        let defaultPreloadTimeout: TimeInterval = 60.0
        let defaultAllowsCellular = true
        let defaultMaxConcurrent = URLSessionConfiguration.default.httpMaximumConnectionsPerHost
        return BMCacheConfiguration(cacheDirectoryURL: cacheDirectoryURL,
                                    maxCacheSizeInBytes: defaultCacheSize,
                                    preloadTaskTimeout: defaultPreloadTimeout,
                                    requestTimeoutInterval: defaultTimeout,
                                    allowsCellularAccess: defaultAllowsCellular,
                                    maxConcurrentDownloads: defaultMaxConcurrent,
                                    customHTTPHeaderFields: nil,
                                    cacheKeyNamer: nil,
                                    cacheSchemePrefix: "bmcache-",
                                    defaultExpirationInterval: 7 * 24 * 60 * 60,
                                    cleanupInterval: 60 * 60,
                                    cleanupStrategy: .leastRecentlyUsed,
                                    minimumDiskSpaceForCaching: 500 * 1024 * 1024)
    }
    public init(cacheDirectoryURL: URL,
         maxCacheSizeInBytes: UInt64,
         preloadTaskTimeout: TimeInterval? = 60.0,
         requestTimeoutInterval: TimeInterval = 30.0,
         allowsCellularAccess: Bool = true,
         maxConcurrentDownloads: Int = URLSessionConfiguration.default.httpMaximumConnectionsPerHost,
         customHTTPHeaderFields: [String: String]? = nil,
         cacheKeyNamer: ((URL) -> String)? = nil,
         cacheSchemePrefix: String = "bmcache-",
         defaultExpirationInterval: TimeInterval? = 7 * 24 * 60 * 60,
         cleanupInterval: TimeInterval = 60 * 60,
         cleanupStrategy: CacheCleanupStrategy = .leastRecentlyUsed,
         minimumDiskSpaceForCaching: UInt64 = 500 * 1024 * 1024) {
        self.cacheDirectoryURL = cacheDirectoryURL
        self.maxCacheSizeInBytes = maxCacheSizeInBytes
        self.preloadTaskTimeout = preloadTaskTimeout
        self.requestTimeoutInterval = requestTimeoutInterval
        self.allowsCellularAccess = allowsCellularAccess
        self.maxConcurrentDownloads = maxConcurrentDownloads
        self.customHTTPHeaderFields = customHTTPHeaderFields
        self.cacheKeyNamer = cacheKeyNamer
        self.cacheSchemePrefix = cacheSchemePrefix
        self.defaultExpirationInterval = defaultExpirationInterval
        self.cleanupInterval = cleanupInterval
        self.cleanupStrategy = cleanupStrategy
        self.minimumDiskSpaceForCaching = minimumDiskSpaceForCaching
    }
    internal func cacheFileURL(for key: String) -> URL {
        return cacheDirectoryURL.appendingPathComponent("\(key).\(cacheFileExtension)")
    }
    internal func metadataFileURL(for key: String) -> URL {
        return cacheDirectoryURL.appendingPathComponent("\(key).\(metadataFileExtension)")
    }
 public enum CacheCleanupStrategy: Equatable {
    case leastRecentlyUsed
    case leastFrequentlyUsed
    case firstInFirstOut
    case expired
    case priorityBased
    case custom(identifier: String, comparator: ((URL, URL) -> Bool), factory: (() -> ((URL, URL) -> Bool))? = nil)
    public static func == (lhs: CacheCleanupStrategy, rhs: CacheCleanupStrategy) -> Bool {
        switch (lhs, rhs) {
        case (.leastRecentlyUsed, .leastRecentlyUsed),
             (.leastFrequentlyUsed, .leastFrequentlyUsed),
             (.firstInFirstOut, .firstInFirstOut),
             (.expired, .expired),
             (.priorityBased, .priorityBased):
            return true
        case (.custom(let lhsId, _, _), .custom(let rhsId, _, _)):
            return lhsId == rhsId
        default:
            return false
        }
    }
    public func getComparator() -> ((URL, URL) -> Bool)? {
        switch self {
        case .custom(_, let comparator, let factory):
            return factory?() ?? comparator
        default:
            return nil
        }
    }
}
 public struct CacheCleanupStrategyWrapper: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case customIdentifier
    }
    private enum StrategyType: String, Codable {
        case leastRecentlyUsed
        case leastFrequentlyUsed
        case firstInFirstOut
        case expired
        case priorityBased
        case custom
    }
    public let strategy: CacheCleanupStrategy
    public init(strategy: CacheCleanupStrategy) {
        self.strategy = strategy
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(StrategyType.self, forKey: .type)
        switch type {
        case .leastRecentlyUsed:
            self.strategy = .leastRecentlyUsed
        case .leastFrequentlyUsed:
            self.strategy = .leastFrequentlyUsed
        case .firstInFirstOut:
            self.strategy = .firstInFirstOut
        case .expired:
            self.strategy = .expired
        case .priorityBased:
            self.strategy = .priorityBased
        case .custom:
            let identifier = try container.decode(String.self, forKey: .customIdentifier)
            
            let factory = BMCacheStrategyRegistry.shared.getFactory(for: identifier)
            self.strategy = .custom(identifier: identifier, comparator: { _, _ in false }, factory: factory)
        }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch strategy {
        case .leastRecentlyUsed:
            try container.encode(StrategyType.leastRecentlyUsed, forKey: .type)
        case .leastFrequentlyUsed:
            try container.encode(StrategyType.leastFrequentlyUsed, forKey: .type)
        case .firstInFirstOut:
            try container.encode(StrategyType.firstInFirstOut, forKey: .type)
        case .expired:
            try container.encode(StrategyType.expired, forKey: .type)
        case .priorityBased:
            try container.encode(StrategyType.priorityBased, forKey: .type)
        case .custom(let identifier, _, _):
            try container.encode(StrategyType.custom, forKey: .type)
            try container.encode(identifier, forKey: .customIdentifier)
        }
    }
}
}
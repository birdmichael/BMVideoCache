import Foundation
public struct BMCacheStatistics: Codable {
    public var totalItemCount: Int = 0
    public var totalCacheSize: UInt64 = 0
    public var oldestItemDate: Date? = nil
    public var newestItemDate: Date? = nil
    public var itemsByPriority: [CachePriority: Int] = [:]
    public var expiredItemCount: Int = 0
    public var averageItemSize: UInt64 = 0
    public var hitCount: UInt64 = 0
    public var missCount: UInt64 = 0
    public var hitRate: Double {
        let total = hitCount + missCount
        return total > 0 ? Double(hitCount) / Double(total) : 0
    }
    public var formattedHitRate: String {
        return String(format: "%.2f%%", hitRate * 100)
    }
    public var utilizationRate: Double = 0
    public var formattedUtilizationRate: String {
        return String(format: "%.2f%%", utilizationRate * 100)
    }
    public var cacheEfficiency: Double {
        return hitRate * utilizationRate
    }
    public var formattedCacheEfficiency: String {
        return String(format: "%.2f%%", cacheEfficiency * 100)
    }
    public var lastCleanupTime: Date? = nil
    public var lastCleanupFreedBytes: UInt64 = 0
    public var totalPreloadRequests: UInt64 = 0
    public var successfulPreloadRequests: UInt64 = 0
    public var preloadSuccessRate: Double {
        return totalPreloadRequests > 0 ? Double(successfulPreloadRequests) / Double(totalPreloadRequests) : 0
    }
    public var formattedPreloadSuccessRate: String {
        return String(format: "%.2f%%", preloadSuccessRate * 100)
    }
    public var summary: String {
        var result = "BMVideoCache Statistics:\n"
        result += "- Total items: \(totalItemCount)\n"
        result += "- Total size: \(formatBytes(totalCacheSize))\n"
        result += "- Hit rate: \(formattedHitRate) (\(hitCount) hits, \(missCount) misses)\n"
        result += "- Utilization: \(formattedUtilizationRate)\n"
        result += "- Cache efficiency: \(formattedCacheEfficiency)\n"
        if let oldest = oldestItemDate {
            result += "- Oldest item: \(formatDate(oldest))\n"
        }
        if let newest = newestItemDate {
            result += "- Newest item: \(formatDate(newest))\n"
        }
        result += "- Items by priority:\n"
        for (priority, count) in itemsByPriority.sorted(by: { $0.key.rawValue > $1.key.rawValue }) {
            result += "  - \(priority): \(count)\n"
        }
        result += "- Expired items: \(expiredItemCount)\n"
        result += "- Average item size: \(formatBytes(averageItemSize))\n"
        if let lastCleanup = lastCleanupTime {
            result += "- Last cleanup: \(formatDate(lastCleanup)) (freed \(formatBytes(lastCleanupFreedBytes)))\n"
        }
        result += "- Preload success rate: \(formattedPreloadSuccessRate) (\(successfulPreloadRequests)/\(totalPreloadRequests))"
        return result
    }
    private func formatBytes(_ bytes: UInt64) -> String {
        let kb = Double(bytes) / 1024.0
        let mb = kb / 1024.0
        let gb = mb / 1024.0
        if gb >= 1.0 {
            return String(format: "%.2f GB", gb)
        } else if mb >= 1.0 {
            return String(format: "%.2f MB", mb)
        } else if kb >= 1.0 {
            return String(format: "%.2f KB", kb)
        } else {
            return "\(bytes) bytes"
        }
    }
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

import Foundation
import CryptoKit
@testable import BMVideoCache

class DirectCacheHelper {
    static func directlyAddItemToCache(for url: URL, size: Int = 1024 * 1024) async {
        // 使用公开API创建资产并缓存
        let assetResult = await BMVideoCache.shared.asset(for: url)
        guard case .success = assetResult else {
            return
        }

        // 等待一些时间以确保缓存完成
        try? await Task.sleep(nanoseconds: 500_000_000)
    }

    static func directlyAddItemsToCacheWithPriorities(lowURLs: [URL], normalURLs: [URL], highURLs: [URL], permanentURLs: [URL], size: Int = 1024 * 1024) async {
        for url in lowURLs {
            await directlyAddItemToCache(for: url, size: size)
            _ = await BMVideoCache.shared.setCachePriority(for: url, priority: .low)
        }

        for url in normalURLs {
            await directlyAddItemToCache(for: url, size: size)
            _ = await BMVideoCache.shared.setCachePriority(for: url, priority: .normal)
        }

        for url in highURLs {
            await directlyAddItemToCache(for: url, size: size)
            _ = await BMVideoCache.shared.setCachePriority(for: url, priority: .high)
        }

        for url in permanentURLs {
            await directlyAddItemToCache(for: url, size: size)
            _ = await BMVideoCache.shared.setCachePriority(for: url, priority: .permanent)
        }
    }

    static func directlyAddExpiredItemToCache(for url: URL, size: Int = 1024 * 1024) async {
        // 首先创建资产
        await directlyAddItemToCache(for: url, size: size)

        // 设置过期时间为过去
        let pastDate = Date().addingTimeInterval(-1)
        _ = await BMVideoCache.shared.setExpirationDate(for: url, date: pastDate)
    }
}



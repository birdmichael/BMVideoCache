# BMVideoCache

BMVideoCache is a high-performance video caching and preloading library for iOS, macOS, iPadOS, and visionOS platforms.

BMVideoCache是一个高性能的视频缓存和预加载库，支持iOS、macOS、iPadOS和visionOS平台。

## Features / 特性

- HTTP/HTTPS video stream caching / HTTP/HTTPS视频流缓存
- Support for MP4 and HLS (m3u8) formats / 支持MP4和HLS (m3u8)格式
- Video preloading / 视频预加载
- Multi-platform support: iOS, macOS, iPadOS, and visionOS / 多平台支持：iOS、macOS、iPadOS和visionOS
- Efficient cache management / 高效缓存管理
- Simple and easy-to-use API / 简单易用的API
- Cache expiration policies / 缓存过期策略
- Cache prioritization / 缓存优先级
- Cache statistics and monitoring / 缓存统计和监控
- Flexible cache cleanup strategies / 灵活的缓存清理策略

## Requirements / 要求

- iOS 14.0+
- macOS 14.0+
- tvOS 14.0+
- visionOS 1.0+
- Swift 5.0+

## Installation / 安装

### Swift Package Manager

在您的 `Package.swift` 文件中添加以下依赖：

```swift
dependencies: [
    .package(url: "https://github.com/birdmichael/BMVideoCache.git", from: "1.0.0")
]
```

然后在您的目标中添加 "BMVideoCache" 作为依赖：

```swift
targets: [
    .target(
        name: "YourTarget",
        dependencies: ["BMVideoCache"]),
]
```

### Xcode

1. 在 Xcode 中，选择 File > Add Packages...
2. 输入仓库 URL: `https://github.com/birdmichael/BMVideoCache.git`
3. 选择版本规则（例如，"Up to Next Major"，从 "1.0.0" 开始）
4. 点击 "Add Package" 按钮
5. 选择您想要添加 BMVideoCache 的目标

## Basic Usage / 基本用法

```swift
import BMVideoCache

// Use directly, no manual initialization needed
let asset = await BMVideoCache.shared.asset(for: videoURL)
let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))

// Preload videos
await BMVideoCache.shared.preload(urls: [videoURL1, videoURL2])

// Clear cache
await BMVideoCache.shared.clearCache()

// Get current cache size
let cacheSize = await BMVideoCache.shared.calculateCurrentCacheSize()
```

## Advanced Configuration / 高级配置

```swift
// Custom configuration
let customConfig = BMCacheConfiguration(
    cacheDirectoryURL: customURL,
    maxCacheSizeInBytes: 1024 * 1024 * 100,
    defaultExpirationInterval: 7 * 24 * 60 * 60,
    cleanupStrategy: .leastRecentlyUsed
)
await BMVideoCache.shared.reconfigure(with: customConfig)

// Set cache priority for specific URL
await BMVideoCache.shared.setCachePriority(for: videoURL, priority: .high)

// Set expiration date for specific URL
let expirationDate = Date().addingTimeInterval(24 * 60 * 60)
await BMVideoCache.shared.setExpirationDate(for: videoURL, date: expirationDate)

// Get cache statistics
let stats = await BMVideoCache.shared.getCacheStatistics()
print("Cache hit rate: \(stats.hitRate * 100)%")
print("Cache item count: \(stats.totalItemCount)")
print("Total cache size: \(stats.totalCacheSize) bytes")
```

## Advanced Features / 高级特性

### HLS (m3u8) Support / HLS (m3u8) 支持

BMVideoCache supports caching and preloading HLS (HTTP Live Streaming) content:

```swift
// 使用方式与MP4相同
let hlsURL = URL(string: "https://example.com/video.m3u8")!
let asset = await BMVideoCache.shared.asset(for: hlsURL)
let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))

// 预加载HLS内容
await BMVideoCache.shared.preload(url: hlsURL)
```

BMVideoCache will automatically:
- Cache the main m3u8 playlist file
- Parse the playlist and cache all segment files (.ts files)
- Handle all the complexity of HLS streaming for you

### Cache Priorities / 缓存优先级

BMVideoCache supports four cache priority levels / BMVideoCache支持四种缓存优先级级别：

- `.low` - Low priority, removed first during cache cleanup / 低优先级，缓存清理时首先移除
- `.normal` - Normal priority (default) / 正常优先级（默认）
- `.high` - High priority, preserved during cache cleanup when possible / 高优先级，缓存清理时尽可能保留
- `.permanent` - Permanent cache, never automatically cleaned up (unless manually cleared) / 永久缓存，不会自动清理（除非手动清除）

### Cache Cleanup Strategies / 缓存清理策略

Supports multiple cache cleanup strategies / 支持多种缓存清理策略：

- `.leastRecentlyUsed` - Least Recently Used (LRU) / 最近最少使用（LRU）
- `.leastFrequentlyUsed` - Least Frequently Used (LFU) / 最不经常使用（LFU）
- `.firstInFirstOut` - First In First Out (FIFO) / 先进先出（FIFO）
- `.expired` - Only clean up expired items / 仅清理过期项目
- `.priorityBased` - Based on priority / 基于优先级
- `.custom` - Custom cleanup strategy / 自定义清理策略

### Logging / 日志

```swift
// Configure logger
await BMVideoCache.shared.configureLogger(
    level: .debug,
    fileLoggingEnabled: true,
    logFileURL: FileManager.default.temporaryDirectory.appendingPathComponent("bmvideocache.log")
)
```

## Performance Optimization / 性能优化

BMVideoCache 包含多项性能优化：

- 批量文件操作以减少磁盘 I/O
- 内存压力响应机制，在系统内存不足时自动释放资源
- 高效的并发控制，避免资源竞争
- 智能预加载算法，优化用户体验
- 文件句柄管理，避免资源泄漏

BMVideoCache 还提供性能监控功能，可以帮助您了解缓存的性能表现：

```swift
// 获取缓存统计信息
let statsResult = await BMVideoCache.shared.getCacheStatistics()
if case .success(let stats) = statsResult {
    print(stats.summary) // 打印完整的缓存统计摘要
}
```

## Memory Management / 内存管理

BMVideoCache 实现了智能内存管理机制：

- 自动响应系统内存压力事件
- 基于优先级的资源释放策略
- 过期缓存自动清理
- 可配置的最大缓存大小

```swift
// 手动设置内存压力级别（通常不需要，系统会自动处理）
BMVideoCache.shared.setMemoryPressureLevel(.medium)

// 设置最小可用磁盘空间
let config = BMCacheConfiguration(
    // 其他配置...
    minimumDiskSpaceForCaching: 1024 * 1024 * 100 // 100MB
)
await BMVideoCache.shared.reconfigure(with: config)
```

## Thread Safety / 线程安全

BMVideoCache is built with Swift concurrency and is fully thread-safe. All public APIs are asynchronous and can be safely called from any thread.

BMVideoCache使用Swift并发构建，完全线程安全。所有公共API都是异步的，可以从任何线程安全调用。

## Error Handling / 错误处理

BMVideoCache is designed to handle network issues and download failures gracefully. It will never crash your app and provides detailed logging for troubleshooting.

BMVideoCache被设计为优雅地处理网络问题和下载失败。它不会导致您的应用程序崩溃，并提供详细的日志以便进行故障排除。

```swift
// 所有API都返回Result类型，便于错误处理
let result = await BMVideoCache.shared.preload(url: videoURL)
switch result {
case .success(let taskId):
    print("Preload task started with ID: \(taskId)")
case .failure(let error):
    print("Preload failed: \(error)")
}
```

## Contributing / 贡献

欢迎对 BMVideoCache 进行贡献！如果您发现了问题或有改进建议，请提交 Issue 或 Pull Request。

贡献指南：

1. Fork 这个仓库
2. 创建您的特性分支 (`git checkout -b feature/amazing-feature`)
3. 提交您的更改 (`git commit -m 'Add some amazing feature'`)
4. 推送到分支 (`git push origin feature/amazing-feature`)
5. 打开一个 Pull Request

## License / 许可证

BMVideoCache is available under the MIT license. See the LICENSE file for more info.

BMVideoCache在MIT许可证下可用。有关更多信息，请参阅LICENSE文件。

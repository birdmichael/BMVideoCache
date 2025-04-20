import Foundation
import AVKit
import Combine

internal final class BMRetryConfiguration {
    let maxRetryCount: Int
    let initialDelaySeconds: Double
    let maxDelaySeconds: Double
    let backoffFactor: Double
    
    init(maxRetryCount: Int = 3, initialDelaySeconds: Double = 1.0, maxDelaySeconds: Double = 15.0, backoffFactor: Double = 2.0) {
        self.maxRetryCount = maxRetryCount
        self.initialDelaySeconds = initialDelaySeconds
        self.maxDelaySeconds = maxDelaySeconds
        self.backoffFactor = backoffFactor
    }
}

internal final class BMAssetLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate, BMDataLoaderManaging, @unchecked Sendable {
    private let cacheManager: BMCacheManager
    private let config: BMCacheConfiguration
    private var activeLoaders: [String: URLSessionDataTask] = [:]
    private let loaderActor = LoaderActor()
    private let loaderQueue = DispatchQueue(label: "com.bmvideocache.loader.queue", attributes: .concurrent)
    private let activeLoadersQueue = DispatchQueue(label: "com.bmvideocache.activeloaders.queue", attributes: .concurrent)
    private weak var internalCacheManagerRef: BMCacheManager?
    private let retryConfig = BMRetryConfiguration()
    private let fileIntegrityQueue = DispatchQueue(label: "com.bmvideocache.fileintegrity.queue")
    
    init(cacheManager: BMCacheManager, config: BMCacheConfiguration) {
        self.cacheManager = cacheManager
        self.internalCacheManagerRef = cacheManager
        self.config = config
        super.init()
        cacheManager.setDataLoaderManagerSync(self)
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        let startTime = CACurrentMediaTime()
        defer {
            _ = (CACurrentMediaTime() - startTime) * 1000
        }

        guard let url = loadingRequest.request.url else {
            loadingRequest.finishLoading(with: NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL, userInfo: nil))
            return false
        }

        let originalURLResult = BMVideoCache.shared.originalURL(from: url)
        guard case .success(let originalURL) = originalURLResult else {
            loadingRequest.finishLoading(with: NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL, userInfo: [NSLocalizedDescriptionKey: "Could not determine original URL from custom scheme URL."]))
            return false
        }

        let key = cacheManager.cacheKeySync(for: originalURL)
        _ = cacheManager.createOrUpdateMetadataSync(for: key, originalURL: originalURL, updateAccessTime: true)

        // 处理加载请求
        Task {
            await processLoadingRequest(loadingRequest, originalURL: originalURL, key: key)
        }

        // 开始预加载
        Task {
            await startPreload(forKey: key, length: 0)
        }

        return true
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        guard let cacheURL = loadingRequest.request.url else {
            return
        }
        let originalURLResult = BMVideoCache.shared.originalURL(from: cacheURL)
        guard case .success(let originalURL) = originalURLResult else {
            return
        }

        let key = cacheManager.cacheKeySync(for: originalURL)
        Task {
            await loaderActor.cancelLoader(for: key)
        }
    }
    func isLoaderActive(forKey key: String) -> Bool {
        // 返回一个默认值，因为异步检查会导致接口变化
        return false
    }
    // 已移除 cleanupInactiveLoaders 相关实现，如需资源释放请补充对应逻辑
    // 已移除 BMDataLoader 相关实现，如需预加载功能请补充 BMDataLoader 类型和逻辑。
    func startPreload(forKey key: String, length: Int64) async -> Result<Void, Error> {
        BMLogger.shared.info("[BMAssetLoaderDelegate] startPreload: key=\(key), length=\(length)")

        // 查找原始URL
        guard let metadata = await cacheManager.getMetadata(for: key) else {
            BMLogger.shared.error("Cannot find metadata for key: \(key)")
            return .failure(NSError(domain: "BMVideoCache", code: -1, userInfo: [NSLocalizedDescriptionKey: "Metadata not found"]))
        }

        let originalURL = metadata.originalURL

        // 检查文件是否已存在
        let fileURL = config.cacheFileURL(for: key)
        if FileManager.default.fileExists(atPath: fileURL.path),
           let attr = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let fileSize = attr[.size] as? UInt64, fileSize > 0 {
            // 文件已存在且大小大于0，标记为完成
            let contentInfo = BMContentInfo(contentType: "video/mp4", contentLength: Int64(fileSize), isByteRangeAccessSupported: true)
            await cacheManager.updateContentInfo(for: key, info: contentInfo)
            await cacheManager.markComplete(for: key, expectedSize: fileSize)
            BMLogger.shared.info("[BMAssetLoaderDelegate] File already exists, marked complete: key=\(key), size: \(fileSize)")
            return .success(())
        }

        // 开始下载
        do {
            try await downloadFile(from: originalURL, key: key, length: length)
            return .success(())
        } catch {
            BMLogger.shared.error("Failed to preload file: \(error)")
            return .failure(error)
        }
    }

    // 处理加载请求
    private func processLoadingRequest(_ request: AVAssetResourceLoadingRequest, originalURL: URL, key: String) async {
        // 检查是否有缓存
        if let metadata = await cacheManager.getMetadata(for: key),
           metadata.isComplete,
           let contentInfo = metadata.contentInfo {
            // 有完整缓存，直接从缓存读取
            if let infoRequest = request.contentInformationRequest {
                infoRequest.contentType = contentInfo.contentType
                infoRequest.contentLength = contentInfo.contentLength
                infoRequest.isByteRangeAccessSupported = contentInfo.isByteRangeAccessSupported
            }

            if let dataRequest = request.dataRequest {
                let requestedOffset = Int64(dataRequest.requestedOffset)
                let requestedLength = Int64(dataRequest.requestedLength)
                let requestedRange = requestedOffset...(requestedOffset + requestedLength - 1)

                if let data = await cacheManager.readData(for: key, range: requestedRange) {
                    dataRequest.respond(with: data)
                    request.finishLoading()
                    BMLogger.shared.debug("Responded with cached data for key: \(key), range: \(requestedRange)")
                    return
                }
            }
        }

        // 如果没有缓存，尝试从文件系统读取
        let fileURL = config.cacheFileURL(for: key)
        if FileManager.default.fileExists(atPath: fileURL.path),
           let attr = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let fileSize = attr[.size] as? UInt64, fileSize > 0 {
            // 文件存在但元数据不完整，自动补全元数据
            let contentInfo = BMContentInfo(contentType: "video/mp4", contentLength: Int64(fileSize), isByteRangeAccessSupported: true)
            await cacheManager.updateContentInfo(for: key, info: contentInfo)
            await cacheManager.markComplete(for: key, expectedSize: fileSize)

            if let infoRequest = request.contentInformationRequest {
                infoRequest.contentType = contentInfo.contentType
                infoRequest.contentLength = contentInfo.contentLength
                infoRequest.isByteRangeAccessSupported = contentInfo.isByteRangeAccessSupported
            }

            if let dataRequest = request.dataRequest {
                let requestedOffset = Int64(dataRequest.requestedOffset)
                let requestedLength = Int64(dataRequest.requestedLength)
                let requestedRange = requestedOffset...(requestedOffset + requestedLength - 1)

                // 直接从文件读取数据
                do {
                    let fileHandle = try FileHandle(forReadingFrom: fileURL)
                    try fileHandle.seek(toOffset: UInt64(requestedOffset))
                    let data = fileHandle.readData(ofLength: Int(requestedLength))
                    try fileHandle.close()

                    if !data.isEmpty {
                        dataRequest.respond(with: data)
                        request.finishLoading()
                        BMLogger.shared.debug("Responded with file data for key: \(key), range: \(requestedRange)")
                        return
                    }
                } catch {
                    BMLogger.shared.error("Failed to read from file: \(error)")
                }
            }
        }

        // 没有缓存或缓存不完整，从网络加载
        do {
            try await loadFromNetwork(request: request, originalURL: originalURL, key: key)
        } catch {
            request.finishLoading(with: error)
            BMLogger.shared.error("Failed to load from network: \(error)")
        }
    }

    private func loadFromNetwork(request: AVAssetResourceLoadingRequest, originalURL: URL, key: String) async throws {
        guard let dataRequest = request.dataRequest else {
            request.finishLoading()
            return
        }
        
        let requestedOffset = Int64(dataRequest.requestedOffset)
        let requestedLength = Int64(dataRequest.requestedLength)
        var urlRequest = URLRequest(url: originalURL)
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.setValue("bytes=\(requestedOffset)-\(requestedOffset + requestedLength - 1)", forHTTPHeaderField: "Range")
        
        var retryCount = 0
        var delay = retryConfig.initialDelaySeconds
        
        while true {
            do {
                let (bytesStream, response) = try await URLSession.shared.bytes(for: urlRequest)
        if let infoRequest = request.contentInformationRequest, let httpResponse = response as? HTTPURLResponse {
            let contentType = (httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "video/mp4") as String
infoRequest.contentType = contentType
            infoRequest.isByteRangeAccessSupported = true
            let contentRange = (httpResponse.value(forHTTPHeaderField: "Content-Range") ?? "") as String
if !contentRange.isEmpty {
    let parts = contentRange.split(separator: "/")
    if let total = parts.last, let totalLength = Int64(total) {
        infoRequest.contentLength = totalLength
        let contentInfo = BMContentInfo(contentType: infoRequest.contentType ?? "video/mp4", contentLength: totalLength, isByteRangeAccessSupported: true)
        await cacheManager.updateContentInfo(for: key, info: contentInfo)
    }
} else {
    let contentLengthStr = (httpResponse.value(forHTTPHeaderField: "Content-Length") ?? "0") as String
    if let totalLength = Int64(contentLengthStr) {
        infoRequest.contentLength = totalLength
        let contentInfo = BMContentInfo(contentType: infoRequest.contentType ?? "video/mp4", contentLength: totalLength, isByteRangeAccessSupported: true)
        await cacheManager.updateContentInfo(for: key, info: contentInfo)
    }
}
        }
        var offset = requestedOffset
        var buffer = [UInt8]()
        let bufferSize = 1024 * 64 // 64KB
        for try await byte in bytesStream {
            buffer.append(byte)
            if buffer.count >= bufferSize {
                let dataChunk = Data(buffer)
                dataRequest.respond(with: dataChunk)
                await cacheManager.cacheData(dataChunk, for: key, at: offset, maxCacheSizeInBytes: config.maxCacheSizeInBytes)
                offset += Int64(dataChunk.count)
                BMLogger.shared.debug("[STREAM DEBUG] Responded \(dataChunk.count) bytes at offset \(offset)")
                buffer.removeAll(keepingCapacity: true)
            }
        }
        // 处理剩余不足一块的数据
        if !buffer.isEmpty {
            let dataChunk = Data(buffer)
            dataRequest.respond(with: dataChunk)
            await cacheManager.cacheData(dataChunk, for: key, at: offset, maxCacheSizeInBytes: config.maxCacheSizeInBytes)
            offset += Int64(dataChunk.count)
            BMLogger.shared.debug("[STREAM DEBUG] Responded \(dataChunk.count) bytes at offset \(offset)")
        }
                request.finishLoading()
                return
            } catch {
                retryCount += 1
                if retryCount > retryConfig.maxRetryCount {
                    BMLogger.shared.error("网络加载失败，已达最大重试次数: \(error.localizedDescription)")
                    throw error
                }
                
                let nextDelay = min(delay * retryConfig.backoffFactor, retryConfig.maxDelaySeconds)
                BMLogger.shared.warning("网络加载失败，将在 \(delay) 秒后重试 (\(retryCount)/\(retryConfig.maxRetryCount)): \(error.localizedDescription)")
                
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                delay = nextDelay
                
                if Task.isCancelled {
                    throw error
                }
            }
        }
    }

    // 下载完整文件（用于预加载）
    private func downloadFile(from url: URL, key: String, length: Int64) async throws {
        var urlRequest = URLRequest(url: url)
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData

        let expectedSize = try await getFileSize(from: url)
        BMLogger.shared.info("Got file size for \(url.lastPathComponent): \(expectedSize) bytes")

        if expectedSize <= 0 {
            throw NSError(domain: "BMVideoCache", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法获取文件大小"])
        }
            
        let contentInfo = BMContentInfo(contentType: "video/mp4", contentLength: Int64(expectedSize), isByteRangeAccessSupported: true)
        await cacheManager.updateContentInfo(for: key, info: contentInfo)

        let fileURL = await cacheManager.getFileURL(for: key)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        
        Task {
            do {
                try await performDownload(from: url, key: key, expectedSize: expectedSize)
            } catch {
                BMLogger.shared.error("下载失败: \(key), 错误: \(error)")
                let resumeData = await getPartialData(for: key)
                if !resumeData.isEmpty {
                    try? await resumeDownload(url: url, key: key, expectedSize: expectedSize, startOffset: Int64(resumeData.count))
                }
            }
        }
    }
    
    // 实际执行下载的方法，使用小块下载并频繁更新进度
    private func performDownload(from url: URL, key: String, expectedSize: UInt64) async throws {
        BMLogger.shared.info("开始下载: \(key), 大小: \(expectedSize) 字节")
        
        var retryCount = 0
        var delay = retryConfig.initialDelaySeconds
        
        while true {
            do {
                var urlRequest = URLRequest(url: url)
                urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
                
                let existingSize = await getDownloadedSize(for: key)
                if existingSize > 0 {
                    urlRequest.setValue("bytes=\(existingSize)-", forHTTPHeaderField: "Range")
                    BMLogger.shared.info("从偏移量 \(existingSize) 恢复下载: \(key)")
                }
                
                let (bytesStream, response) = try await URLSession.shared.bytes(for: urlRequest)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw NSError(domain: "BMVideoCache", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效的响应"])
                }
                
                let contentInfo = extractContentInfo(from: httpResponse)
                await cacheManager.updateContentInfo(for: key, info: contentInfo)
                
                var buffer = Data()
                let chunkSize = 256 * 1024
                var totalBytesReceived: Int64 = Int64(existingSize)
                var lastProgressReportTime = Date().timeIntervalSince1970
                var lastReportedProgressValue: Double = Double(existingSize) / Double(expectedSize) * 100.0
        
                for try await byte in bytesStream {
                    buffer.append(byte)
                    totalBytesReceived += 1
                    
                    if buffer.count >= chunkSize {
                        let offset = totalBytesReceived - Int64(buffer.count)
                        await cacheManager.cacheData(buffer, for: key, at: offset, maxCacheSizeInBytes: config.maxCacheSizeInBytes)
                        buffer.removeAll(keepingCapacity: true)
                        
                        let currentTime = Date().timeIntervalSince1970
                        let progress = Double(totalBytesReceived) / Double(expectedSize) * 100.0
                        
                        if (currentTime - lastProgressReportTime >= 0.1) || 
                           (abs(progress - lastReportedProgressValue) >= 0.5) {
                            lastProgressReportTime = currentTime
                            lastReportedProgressValue = progress
                            
                            if let metadata = await cacheManager.getMetadata(for: key) {
                                if let onProgress = await cacheManager.onProgress {
                                    onProgress(key, metadata.originalURL, progress, UInt64(totalBytesReceived), expectedSize)
                                }
                            }
                            
                            if Task.isCancelled {
                                throw CancellationError()
                            }
                        }
                    }
                }
                
                if !buffer.isEmpty {
                    let offset = totalBytesReceived - Int64(buffer.count)
                    await cacheManager.cacheData(buffer, for: key, at: offset, maxCacheSizeInBytes: config.maxCacheSizeInBytes)
                }
                
                await cacheManager.markComplete(for: key, expectedSize: UInt64(totalBytesReceived))
                BMLogger.shared.info("下载完成: \(key), 大小: \(totalBytesReceived) 字节")
                
                if let metadata = await cacheManager.getMetadata(for: key) {
                    if let onProgress = await cacheManager.onProgress {
                        onProgress(key, metadata.originalURL, 100.0, UInt64(totalBytesReceived), expectedSize)
                    }
                }
                
                await loaderActor.removeLoader(for: key)
                
                let success = await verifyFileIntegrity(for: key, expectedSize: UInt64(totalBytesReceived))
                if !success {
                    BMLogger.shared.warning("文件完整性验证失败: \(key)")
                }
                
                return
                
            } catch is CancellationError {
                BMLogger.shared.info("下载取消: \(key)")
                throw CancellationError()
                
            } catch {
                retryCount += 1
                if retryCount > retryConfig.maxRetryCount {
                    BMLogger.shared.error("下载失败，已达最大重试次数: \(key), 错误: \(error)")
                    throw error
                }
                
                let nextDelay = min(delay * retryConfig.backoffFactor, retryConfig.maxDelaySeconds)
                BMLogger.shared.warning("下载失败，将在 \(delay) 秒后重试 (\(retryCount)/\(retryConfig.maxRetryCount)): \(key)")
                
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                delay = nextDelay
                
                if Task.isCancelled {
                    throw CancellationError()
                }
            }
        }
    }

    // 进度跟踪代理
    private class ProgressTrackingDelegate: NSObject, URLSessionDataDelegate {
        private let key: String
        private weak var cacheManager: BMCacheManager?
        private let config: BMCacheConfiguration
        private var expectedSize: Int64 = 0
        private var receivedSize: Int64 = 0
        private var receivedData = Data()
        private var lastWritePosition: Int64 = 0
        private let writeChunkSize: Int = 1024 * 1024
        private let completion: (Result<Void, Error>) -> Void
        private var lastProgressUpdateTime: TimeInterval = 0
        private let progressUpdateInterval: TimeInterval = 0.1 // 进度更新间隔（秒）

        init(key: String, cacheManager: BMCacheManager?, config: BMCacheConfiguration, expectedSize: Int64, completion: @escaping (Result<Void, Error>) -> Void) {
            self.key = key
            self.cacheManager = cacheManager
            self.config = config
            self.expectedSize = expectedSize
            self.completion = completion
            self.lastProgressUpdateTime = CACurrentMediaTime()
            super.init()
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            if let httpResponse = response as? HTTPURLResponse,
               let contentLengthStr = httpResponse.value(forHTTPHeaderField: "Content-Length"),
               let contentLength = Int64(contentLengthStr) {
                expectedSize = contentLength
            } else if let expectedLength = dataTask.response?.expectedContentLength, expectedLength != -1 {
                expectedSize = expectedLength
            }

            // 初始化文件和元数据
            Task {
                guard let cacheManager = cacheManager else { return }

                // 更新内容信息
                await cacheManager.updateContentInfo(for: key, info: BMContentInfo(
                    contentType: "video/mp4",
                    contentLength: expectedSize,
                    isByteRangeAccessSupported: true
                ))

                // 确保文件存在
                let fileURL = await cacheManager.configuration.cacheFileURL(for: key)
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    FileManager.default.createFile(atPath: fileURL.path, contents: nil)
                }
            }

            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            // 添加到接收数据缓冲区
            receivedData.append(data)
            receivedSize += Int64(data.count)

            // 如果缓冲区达到写入块大小或已经过了更新间隔，则写入文件
            let now = CACurrentMediaTime()
            if receivedData.count >= writeChunkSize {
                writeDataToFile()
            }
            
            // 触发进度回调（控制频率，避免过于频繁）
            if now - lastProgressUpdateTime >= progressUpdateInterval {
                lastProgressUpdateTime = now
                updateProgress()
            }
        }
        
        // 更新并触发进度回调
        private func updateProgress() {
            guard let cacheManager = cacheManager, expectedSize > 0 else { return }
            
            let progress = Double(receivedSize) / Double(expectedSize)
            BMLogger.shared.debug("[ProgressTrackingDelegate] Progress: \(Int(progress * 100))% (\(receivedSize)/\(expectedSize)) for key: \(key)")
            
            // 获取原始URL
            Task {
                if let metadata = await cacheManager.getMetadata(for: key) {
                    let originalURL = metadata.originalURL
                    if let onProgress = await cacheManager.onProgress {
                        onProgress(key, originalURL, progress * 100, UInt64(receivedSize), UInt64(expectedSize))
                    }
                }
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if error == nil {
                // 下载完成，写入剩余数据并更新最终进度
                writeDataToFile()

                // 打印下载完成日志
                BMLogger.shared.info("[PROGRESS DEBUG] Download completed for \(key), received \(receivedSize) bytes")

                // 发送最终的100%进度
                if let cacheManager = cacheManager {
                    Task {
                        if let metadata = await cacheManager.getMetadata(for: key) {
                            let originalURL = metadata.originalURL
                            if let onProgress = await cacheManager.onProgress {
                                onProgress(key, originalURL, 100.0, UInt64(receivedSize), UInt64(expectedSize))
                            }
                        }
                        
                        await cacheManager.markComplete(for: key, expectedSize: UInt64(receivedSize))
                        // 打印标记完成日志
                        BMLogger.shared.info("[PROGRESS DEBUG] Marked complete: key=\(key), size=\(receivedSize)")
                    }
                }
            } else {
                BMLogger.shared.error("Download failed with error: \(error?.localizedDescription ?? "Unknown error")")
            }
        }

        private func writeDataToFile() {
            guard !receivedData.isEmpty, let cacheManager = cacheManager else { return }

            // 创建一个临时副本并清空缓冲区
            let dataToWrite = receivedData
            receivedData = Data() // Clear buffer

            // 正确计算偏移量：当前已接收的总字节数 - 本次要写入的字节数
            let offset = self.receivedSize - Int64(dataToWrite.count)
            // 确保 offset 不为负（虽然理论上不应该）
            let safeOffset = max(0, offset)

            BMLogger.shared.debug("[ProgressTrackingDelegate] Writing \(dataToWrite.count) bytes for key \(key) at offset \(safeOffset) (Total received: \(self.receivedSize))")

            Task {
                await cacheManager.cacheData(dataToWrite, for: key, at: safeOffset, maxCacheSizeInBytes: config.maxCacheSizeInBytes)
                
                // 每次写入后也更新进度
                updateProgress()
            }
        }
    }

    // 获取文件大小
    private func getDownloadedSize(for key: String) async -> UInt64 {
        guard let fileURL = try? await cacheManager.getFileURL(for: key) else {
            return 0
        }
        
        if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let size = attributes[.size] as? UInt64 {
            return size
        }
        return 0
    }
    
    private func getPartialData(for key: String) async -> Data {
        let fileURL = await cacheManager.getFileURL(for: key)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return (try? Data(contentsOf: fileURL)) ?? Data()
        }
        return Data()
    }
    
    private func resumeDownload(url: URL, key: String, expectedSize: UInt64, startOffset: Int64) async throws {
        BMLogger.shared.info("尝试从偏移量 \(startOffset) 恢复下载: \(key)")
        Task {
            do {
                try await performDownload(from: url, key: key, expectedSize: expectedSize)
            } catch {
                BMLogger.shared.error("恢复下载失败: \(key), 错误: \(error)")
            }
        }
    }
    
    private func verifyFileIntegrity(for key: String, expectedSize: UInt64) async -> Bool {
        let fileURL = await cacheManager.getFileURL(for: key)
        
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            return false
        }
        
        var fileAttributes: [FileAttributeKey: Any]?
        do {
            fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        } catch {
            BMLogger.shared.error("获取文件属性失败: \(fileURL.path), 错误: \(error)")
            return false
        }
        
        guard let fileSize = fileAttributes?[.size] as? UInt64 else {
            return false
        }
        
        if fileSize != expectedSize {
            BMLogger.shared.warning("文件大小不匹配: 期望 \(expectedSize), 实际 \(fileSize)")
            return false
        }
        
        return true
    }
    
    private func extractContentInfo(from response: HTTPURLResponse) -> BMContentInfo {
        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? "video/mp4"
        var contentLength: Int64 = 0
        
        if let contentRange = response.value(forHTTPHeaderField: "Content-Range") {
            let components = contentRange.components(separatedBy: "/")
            if let lastComponent = components.last, let length = Int64(lastComponent) {
                contentLength = length
            }
        } else if let lengthStr = response.value(forHTTPHeaderField: "Content-Length"), let length = Int64(lengthStr) {
            contentLength = length
        }
        
        return BMContentInfo(contentType: contentType, contentLength: contentLength, isByteRangeAccessSupported: true)
    }
    
    private func getFileSize(from url: URL) async throws -> UInt64 {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"

        return try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.dataTask(with: request) { _, response, error in
                if let error = error {
                    BMLogger.shared.error("Failed to get file size: \(error)")
                    continuation.resume(returning: 0)
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    BMLogger.shared.error("Invalid response for HEAD request")
                    continuation.resume(returning: 0)
                    return
                }

                // 尝试从 Content-Length 获取文件大小
                if let contentLengthStr = httpResponse.value(forHTTPHeaderField: "Content-Length"),
                   let contentLength = UInt64(contentLengthStr) {
                    BMLogger.shared.info("Got file size from HEAD request: \(contentLength) bytes")
                    continuation.resume(returning: contentLength)
                } else {
                    BMLogger.shared.warning("No Content-Length in HEAD response")
                    continuation.resume(returning: 0)
                }
            }
            task.resume()
        }
    }





    // 取消所有活跃的加载任务
    private func cancelAllLoaders() {
        Task {
            await loaderActor.cancelAllLoaders()
        }
    }

    // 清理不活跃的加载器
    private func cleanupInactiveLoaders() {
        Task {
            await loaderActor.cleanupInactiveLoaders()
        }
    }

    // 管理加载器的Actor
    private actor LoaderActor {
        private var loaders: [String: URLSessionDataTask] = [:]

        func addLoader(_ task: URLSessionDataTask, for key: String) {
            loaders[key] = task
        }

        func removeLoader(for key: String) {
            loaders[key] = nil
        }

        func cancelLoader(for key: String) {
            if let task = loaders[key] {
                task.cancel()
                loaders[key] = nil
                BMLogger.shared.debug("Cancelled loading request for key: \(key)")
            }
        }

        func cancelAllLoaders() {
            for (_, task) in loaders {
                task.cancel()
            }
            loaders.removeAll()
        }

        func cleanupInactiveLoaders() {
            let inactiveKeys = loaders.filter { $0.value.state == .completed || $0.value.state == .canceling }.map { $0.key }
            for key in inactiveKeys {
                loaders.removeValue(forKey: key)
            }
        }
    }
}

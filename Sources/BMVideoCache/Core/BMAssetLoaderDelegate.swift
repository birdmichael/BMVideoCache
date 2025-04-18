import Foundation
import AVKit
import Combine
internal final class BMAssetLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate, BMDataLoaderManaging {
    private let cacheManager: BMCacheManager
    private let config: BMCacheConfiguration
    private var activeLoaders = [String: Any]()
    private let accessQueue = DispatchQueue(label: "com.bmvideocache.loaderdelegate.access.queue")
    private weak var internalCacheManagerRef: BMCacheManager?
    init(cacheManager: BMCacheManager, config: BMCacheConfiguration) {
        self.cacheManager = cacheManager
        self.internalCacheManagerRef = cacheManager
        self.config = config
        super.init()
        cacheManager.setDataLoaderManagerSync(self)
    }
    deinit {
        accessQueue.sync {
            for (_, loader) in activeLoaders {
                if let dataLoader = loader as? BMDataLoader {
                    dataLoader.cancel()
                }
            }
            activeLoaders.removeAll()
        }
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        let startTime = Date()
        defer {
            let elapsedTime = Date().timeIntervalSince(startTime) * 1000
            Task { await BMLogger.shared.performance("Resource loader decision", durationMs: elapsedTime) }
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
        let workItem = DispatchWorkItem {
            let loader: Any
            if let existingLoader = self.activeLoaders[key] as? BMDataLoader {
                loader = existingLoader
            } else {
                let newLoader = BMDataLoader(originalURL: originalURL, cacheManager: self.cacheManager, config: self.config)
                self.activeLoaders[key] = newLoader
                loader = newLoader
            }
            if let dataLoader = loader as? BMDataLoader {
                dataLoader.add(request: loadingRequest)
            }
        }
        accessQueue.async(execute: workItem)
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
        accessQueue.async {
            if let loader = self.activeLoaders[key] as? BMDataLoader {
                loader.remove(request: loadingRequest)
                if loader.hasNoPendingRequests() {
                    loader.cancel()
                    self.activeLoaders.removeValue(forKey: key)
                }
            } else {
            }
        }
    }
    func isLoaderActive(forKey key: String) -> Bool {
        var result = false
        accessQueue.sync {
            result = self.activeLoaders[key] != nil
        }
        return result
    }
    private func cleanupInactiveLoaders() {
        accessQueue.async(flags: .barrier) {
            var loadersToRemove = [String]()
            for (key, loader) in self.activeLoaders {
                if let dataLoader = loader as? BMDataLoader, dataLoader.hasNoPendingRequests() {
                    loadersToRemove.append(key)
                }
            }
            for key in loadersToRemove {
                if let dataLoader = self.activeLoaders[key] as? BMDataLoader {
                    dataLoader.cancel()
                }
                self.activeLoaders.removeValue(forKey: key)
            }
        }
    }
    func startPreload(forKey key: String, length: Int64) async {
        let metadata = cacheManager.getMetadataSync(for: key)
        guard let metadata = metadata else {
            return
        }
        var loader: BMDataLoader?
        accessQueue.sync {
            if let existingLoader = self.activeLoaders[key] as? BMDataLoader {
                loader = existingLoader
            } else {
                let newLoader = BMDataLoader(originalURL: metadata.originalURL, cacheManager: self.cacheManager, config: self.config)
                self.activeLoaders[key] = newLoader
                loader = newLoader
            }
        }
        if let dataLoader = loader {
            await dataLoader.addPreloadRequest(length: length)
        }
    }
}
internal final class BMDataLoader {
    private let originalURL: URL
    private let cacheManager: BMCacheManager
    private let config: BMCacheConfiguration
    private var pendingRequests = Set<AVAssetResourceLoadingRequest>()
    private let accessQueue = DispatchQueue(label: "com.bmvideocache.dataloader.access.queue", attributes: .concurrent)
    private let writeQueue = DispatchQueue(label: "com.bmvideocache.dataloader.write.queue")
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var receivedData = Data()
    private var expectedContentLength: Int64 = 0
    private var currentOffset: Int64 = 0
    private var isByteRangeAccessSupported = false
    private var contentType: String?
    private var isPreloading = false
    private var isCancelled = false
    private var isHLSContent = false
    private var hlsSegmentTasks = [URLSessionDataTask]()
    init(originalURL: URL, cacheManager: BMCacheManager, config: BMCacheConfiguration) {
        self.originalURL = originalURL
        self.cacheManager = cacheManager
        self.config = config
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = config.requestTimeoutInterval
        sessionConfig.allowsCellularAccess = config.allowsCellularAccess
        sessionConfig.httpMaximumConnectionsPerHost = config.maxConcurrentDownloads
        sessionConfig.httpAdditionalHeaders = config.customHTTPHeaderFields
        self.session = URLSession(configuration: sessionConfig, delegate: nil, delegateQueue: nil)
    }
    deinit {
        accessQueue.sync {
            if !isCancelled {
                cancel()
            }
        }
    }
    func add(request: AVAssetResourceLoadingRequest) {
        accessQueue.async(flags: .barrier) {
            self.pendingRequests.insert(request)
        }
        if task == nil && !isCancelled {
            startLoading()
        } else {
            processPendingRequests()
        }
    }
    func remove(request: AVAssetResourceLoadingRequest) {
        accessQueue.async(flags: .barrier) {
            self.pendingRequests.remove(request)
        }
    }
    func hasNoPendingRequests() -> Bool {
        var isEmpty = false
        accessQueue.sync {
            isEmpty = self.pendingRequests.isEmpty
        }
        return isEmpty && !isPreloading
    }
    func cancel() {
        accessQueue.async(flags: .barrier) {
            if self.isCancelled {
                return
            }
            self.isCancelled = true
            self.task?.cancel()
            self.task = nil

            // 取消所有HLS分段任务
            for segmentTask in self.hlsSegmentTasks {
                segmentTask.cancel()
            }
            self.hlsSegmentTasks.removeAll()

            self.session?.invalidateAndCancel()
            self.session = nil
            for request in self.pendingRequests {
                request.finishLoading(with: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, userInfo: nil))
            }
            self.pendingRequests.removeAll()
        }
    }
    func addPreloadRequest(length: Int64) async {
        isPreloading = true
        if task == nil && !isCancelled {
            startPreloadingWithLength(length)
        }
        if let timeout = config.preloadTaskTimeout {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        }
        isPreloading = false
    }
    private func startLoading() {
        var request = URLRequest(url: originalURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let customHeaders = config.customHTTPHeaderFields {
            for (field, value) in customHeaders {
                request.setValue(value, forHTTPHeaderField: field)
            }
        }
        task = session?.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            if let error = error {
                if (error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorCancelled {
                    return
                }
                Task { await BMLogger.shared.error("Loading failed for URL: \(self.originalURL.absoluteString), Error: \(error)") }
                self.failAllRequests(with: error)
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                self.failAllRequests(with: NSError(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse, userInfo: nil))
                return
            }
            guard 200...299 ~= httpResponse.statusCode else {
                self.failAllRequests(with: NSError(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP status code: \(httpResponse.statusCode)"]))
                return
            }
            self.handleSuccessResponse(httpResponse, data: data)
        }
        task?.resume()
    }
    private func startPreloadingWithLength(_ length: Int64) {
        var request = URLRequest(url: originalURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let customHeaders = config.customHTTPHeaderFields {
            for (field, value) in customHeaders {
                request.setValue(value, forHTTPHeaderField: field)
            }
        }
        if isByteRangeAccessSupported {
            request.setValue("bytes=0-\(length - 1)", forHTTPHeaderField: "Range")
        }
        task = session?.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            if let error = error {
                if (error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorCancelled {
                    return
                }
                Task { await BMLogger.shared.error("Preload failed for URL: \(self.originalURL.absoluteString), Error: \(error)") }
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                return
            }
            guard 200...299 ~= httpResponse.statusCode || httpResponse.statusCode == 206 else {
                return
            }
            self.handleSuccessResponse(httpResponse, data: data)
        }
        task?.resume()
    }
    private func handleSuccessResponse(_ response: HTTPURLResponse, data: Data?) {
        let startTime = Date()
        defer {
            let elapsedTime = Date().timeIntervalSince(startTime) * 1000
            Task { await BMLogger.shared.performance("Handle response for \(originalURL.lastPathComponent)", durationMs: elapsedTime) }
        }
        contentType = response.mimeType ?? "application/octet-stream"
        expectedContentLength = response.expectedContentLength
        if let rangeHeader = response.allHeaderFields["Accept-Ranges"] as? String {
            isByteRangeAccessSupported = rangeHeader.lowercased() == "bytes"
        } else {
            isByteRangeAccessSupported = response.statusCode == 206
        }
        let contentInfo = BMContentInfo(
            contentType: contentType ?? "application/octet-stream",
            contentLength: expectedContentLength,
            isByteRangeAccessSupported: isByteRangeAccessSupported
        )

        // 检查是否为HLS内容
        isHLSContent = contentInfo.isHLSContent || originalURL.pathExtension.lowercased() == "m3u8"

        let key = cacheManager.cacheKeySync(for: originalURL)
        Task {
            await cacheManager.updateContentInfo(for: key, info: contentInfo)
        }

        if let receivedData = data {
            self.receivedData = receivedData
            self.currentOffset = Int64(receivedData.count)
            Task {
                await cacheManager.cacheData(receivedData, for: key, at: 0)
            }

            // 如果是HLS内容，解析m3u8文件并缓存分段
            if isHLSContent, let m3u8Content = String(data: receivedData, encoding: .utf8) {
                processHLSContent(m3u8Content)
            }

            processPendingRequests()
        }
    }
    private func processPendingRequests() {
        let startTime = Date()
        accessQueue.async {
            for request in self.pendingRequests {
                self.processSingleRequest(request)
            }
            let elapsedTime = Date().timeIntervalSince(startTime) * 1000
            Task { await BMLogger.shared.performance("Process pending requests", durationMs: elapsedTime) }
        }
    }
    private func processSingleRequest(_ request: AVAssetResourceLoadingRequest) {
        if let dataRequest = request.dataRequest, let infoRequest = request.contentInformationRequest {
            if let type = contentType {
                infoRequest.contentType = type
            }
            if expectedContentLength > 0 {
                infoRequest.contentLength = expectedContentLength
            }
            infoRequest.isByteRangeAccessSupported = isByteRangeAccessSupported
            let requestedOffset = dataRequest.requestedOffset
            let requestedLength = dataRequest.requestedLength
            let currentLength = Int64(receivedData.count)
            if requestedOffset < currentLength {
                let availableLength = min(Int(currentLength - requestedOffset), requestedLength)
                let range = Int(requestedOffset)..<Int(requestedOffset) + availableLength
                let requestedData = receivedData.subdata(in: range)
                dataRequest.respond(with: requestedData)
                if requestedOffset + Int64(availableLength) >= requestedOffset + Int64(requestedLength) {
                    request.finishLoading()
                }
            }
        }
    }
    private func failAllRequests(with error: Error) {
        accessQueue.async(flags: .barrier) {
            for request in self.pendingRequests {
                request.finishLoading(with: error)
            }
            self.pendingRequests.removeAll()
        }
    }

    private func processHLSContent(_ m3u8Content: String) {
        // 解析m3u8文件内容
        let lines = m3u8Content.components(separatedBy: .newlines)
        var segmentURLs: [URL] = []

        // 获取m3u8文件的基础URL
        let baseURL = originalURL.deletingLastPathComponent()

        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)

            // 跳过注释和标签行
            if trimmedLine.isEmpty || trimmedLine.hasPrefix("#") {
                continue
            }

            // 处理分段URL
            if let segmentURL = URL(string: trimmedLine, relativeTo: baseURL) {
                segmentURLs.append(segmentURL)
            }
        }

        // 缓存所有分段
        for segmentURL in segmentURLs {
            cacheHLSSegment(segmentURL)
        }
    }

    private func cacheHLSSegment(_ segmentURL: URL) {
        var request = URLRequest(url: segmentURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let customHeaders = config.customHTTPHeaderFields {
            for (field, value) in customHeaders {
                request.setValue(value, forHTTPHeaderField: field)
            }
        }

        let segmentTask = session?.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self, !self.isCancelled else { return }

            if let error = error {
                Task { await BMLogger.shared.error("HLS segment loading failed for URL: \(segmentURL.absoluteString), Error: \(error)") }
                return
            }

            guard let httpResponse = response as? HTTPURLResponse, 200...299 ~= httpResponse.statusCode else {
                return
            }

            if let segmentData = data {
                let key = self.cacheManager.cacheKeySync(for: segmentURL)
                Task {
                    // 创建分段的元数据
                    _ = await self.cacheManager.createOrUpdateMetadata(for: key, originalURL: segmentURL)

                    // 缓存分段数据
                    await self.cacheManager.cacheData(segmentData, for: key, at: 0)

                    await BMLogger.shared.debug("Cached HLS segment: \(segmentURL.lastPathComponent)")
                }
            }
        }

        if let task = segmentTask {
            hlsSegmentTasks.append(task)
            task.resume()
        }
    }
}

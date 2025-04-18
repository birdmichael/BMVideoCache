import Foundation

class MockURLProtocol: URLProtocol {
    static var mockResponses = [URL: (data: Data, response: HTTPURLResponse, error: Error?)]()
    
    static func registerMockResponse(for url: URL, data: Data, statusCode: Int = 200, error: Error? = nil) {
        let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "video/mp4", "Accept-Ranges": "bytes"])!
        mockResponses[url] = (data, response, error)
    }
    
    static func reset() {
        mockResponses.removeAll()
    }
    
    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }
    
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }
    
    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        
        if let mockData = MockURLProtocol.mockResponses[url] {
            if let error = mockData.error {
                client?.urlProtocol(self, didFailWithError: error)
            } else {
                client?.urlProtocol(self, didReceive: mockData.response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: mockData.data)
                client?.urlProtocolDidFinishLoading(self)
            }
        } else {
            // 如果没有找到匹配的模拟响应，返回404错误
            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    
    override func stopLoading() {
        // 不需要实现任何内容
    }
}

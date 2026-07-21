import CryptoKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct HTTPResult: Sendable {
    let statusCode: Int
    let data: Data
    let headers: [String: String]
}

protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResult
}

final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func send(_ request: URLRequest) async throws -> HTTPResult {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            headers[String(describing: key).lowercased()] = String(describing: value)
        }
        return HTTPResult(statusCode: response.statusCode, data: data, headers: headers)
    }
}

struct RequestFactory: Sendable {
    let baseURL: URL
    let apiKey: String

    func post(path: String, body: Data, idempotencyKey: String) -> URLRequest {
        let compressed = Gzip.compress(body)
        var request = commonRequest(path: path)
        request.httpMethod = "POST"
        request.httpBody = compressed
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        request.setValue(signature(for: compressed), forHTTPHeaderField: "X-AttrKit-Signature")
        return request
    }

    func get(path: String, etag: String?) -> URLRequest {
        var request = commonRequest(path: path)
        request.httpMethod = "GET"
        request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key")
        request.setValue(signature(for: Data()), forHTTPHeaderField: "X-AttrKit-Signature")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        return request
    }

    private func commonRequest(path: String) -> URLRequest {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("AttrKit-Publishable \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("ios/\(attrKitSDKVersion)", forHTTPHeaderField: "X-AttrKit-SDK")
        request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-AttrKit-Request-ID")
        return request
    }

    private func signature(for body: Data) -> String {
        let key = SymmetricKey(data: Data(apiKey.utf8))
        let authentication = HMAC<SHA256>.authenticationCode(for: body, using: key)
        return "v1=" + Data(authentication).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

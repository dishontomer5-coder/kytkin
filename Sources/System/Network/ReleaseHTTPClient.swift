// P6-3: the one network client in Kytkin (the optional update check, `UpdateChecker`). Never compiled into the
// tests (they use a fake). An ephemeral session with no cache, no cookies and no credential store, so nothing is kept
// between checks; only the headers the caller passes (a fixed User-Agent and Accept). It never logs the response.

import Foundation

final class ReleaseHTTPClient: HTTPGetting, @unchecked Sendable {   // @unchecked: URLSession is thread-safe
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    func get(_ url: URL, headers: [String: String]) async -> (status: Int, body: Data)? {
        guard url.scheme == "https" else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        return (http.statusCode, data)
    }
}

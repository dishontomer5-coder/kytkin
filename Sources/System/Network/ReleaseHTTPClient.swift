// P6-3: the one network client in Kytkin (the optional update check, `UpdateChecker`). Never compiled into the
// tests (they use a fake). An ephemeral session with no cache, no cookies and no credential store, so nothing is kept
// between checks; only the headers the caller passes (a fixed User-Agent and Accept). It never logs the response.

import Foundation

final class ReleaseHTTPClient: HTTPGetting, @unchecked Sendable {   // @unchecked: URLSession is thread-safe
    private let session: URLSession
    private let redirects = RedirectGuard()

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
        guard let (data, response) = try? await session.data(for: request, delegate: redirects),
              let http = response as? HTTPURLResponse else { return nil }
        return (http.statusCode, data)
    }
}

/// P6-3 QA: follows a redirect only to https://api.github.com (a moved repository); anything else is not followed (the
/// 3xx answer comes back and the check stays quiet).
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        UpdateCheck.allowsRedirect(to: request.url) ? request : nil
    }
}

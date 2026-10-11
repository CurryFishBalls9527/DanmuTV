import Foundation

public enum BiliError: LocalizedError {
    case api(code: Int, message: String)
    case http(Int)
    case invalidResponse
    case notLoggedIn

    public var errorDescription: String? {
        switch self {
        case .api(-352, _), .api(-412, _): return "请求被 B 站风控拦截，请稍后再试"
        case let .api(code, message): return message.isEmpty ? "错误 \(code)" : "\(message) (\(code))"
        case .http(412): return "请求过于频繁，已被 B 站风控拦截，请稍后再试 (HTTP 412)"
        case let .http(status): return "HTTP \(status)"
        case .invalidResponse: return "无法解析服务器响应"
        case .notLoggedIn: return "请先登录"
        }
    }
}

public enum Sign {
    case none, wbi, app
}

/// A logged-in Bilibili account (credentials from TV QR login).
public struct Account: Codable, Identifiable, Equatable, Sendable {
    public var mid: Int
    public var name: String
    public var face: String
    public var cookies: [String: String]
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date

    public var id: Int { mid }
    public var csrf: String { cookies["bili_jct"] ?? "" }

    public init(mid: Int, name: String, face: String, cookies: [String: String], accessToken: String, refreshToken: String, expiresAt: Date) {
        self.mid = mid
        self.name = name
        self.face = face
        self.cookies = cookies
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

/// Thread-safe HTTP client for Bilibili. Cookies come from the active account plus an
/// anonymous buvid, which many endpoints require to avoid risk control (-352 / -412).
public final class BiliClient: @unchecked Sendable {
    public static let shared = BiliClient()

    public static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Safari/605.1.15"
    public static let referer = "https://www.bilibili.com"

    /// Headers the player must send for Bilibili CDN media (403 without Referer).
    public static var mediaHeaders: [String: String] {
        ["User-Agent": userAgent, "Referer": referer]
    }

    /// Called (on an arbitrary thread) when the server says a logged-in session is no longer valid.
    public var onAuthFailure: (@Sendable () -> Void)? {
        get { lock.withLock { authFailureHandler } }
        set { lock.withLock { authFailureHandler = newValue } }
    }

    private var authFailureHandler: (@Sendable () -> Void)?

    public let session: URLSession
    private let lock = NSLock()
    private var account: Account?
    private var mixinKey: String?
    private var mixinKeyDate: Date?
    private var buvid3: String?
    private var buvid4: String?

    private init() {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)
        buvid3 = UserDefaults.standard.string(forKey: "buvid3")
        buvid4 = UserDefaults.standard.string(forKey: "buvid4")
    }

    public func setAccount(_ account: Account?) {
        lock.withLock {
            self.account = account
            self.mixinKey = nil
        }
    }

    public var currentAccount: Account? { lock.withLock { account } }
    public var currentBuvid: String { lock.withLock { buvid3 ?? "" } }

    /// Account cookies (SESSDATA, bili_jct) are only ever sent to *.bilibili.com; image/video CDNs get none.
    static func sendsCookies(to url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return host == "bilibili.com" || host.hasSuffix(".bilibili.com")
    }

    func cookieHeader(anonymous: Bool, as override: Account? = nil) -> String {
        lock.withLock {
            var cookies = anonymous ? [:] : ((override ?? account)?.cookies ?? [:])
            if let buvid3, cookies["buvid3"] == nil { cookies["buvid3"] = buvid3 }
            if let buvid4, cookies["buvid4"] == nil { cookies["buvid4"] = buvid4 }
            return cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        }
    }

    // MARK: Requests

    /// GET returning the full response envelope (`code`, `data`/`result`).
    /// `anonymous: true` omits the account's cookies (e.g. the "anonymous mode" for 热门).
    /// `as:` sends another account's credentials without touching the shared active account (used during login).
    public func get(_ url: String, _ params: [String: String] = [:], sign: Sign = .none, anonymous: Bool = false,
                    as override: Account? = nil) async throws -> JSON
    {
        try await withRetry {
            try await self.ensureBuvid()
            let query: String
            switch sign {
            case .none: query = Signing.query(params)
            case .app:
                var p = params
                if !anonymous, let token = (override ?? self.currentAccount)?.accessToken, !token.isEmpty { p["access_key"] = token }
                query = Signing.appSigned(p)
            case .wbi: query = Signing.wbiSigned(params, mixinKey: try await self.wbiKey())
            }
            let full = query.isEmpty ? url : url + (url.contains("?") ? "&" : "?") + query
            guard let u = URL(string: full) else { throw BiliError.invalidResponse }
            return try await self.send(URLRequest(url: u), anonymous: anonymous, as: override)
        }
    }

    /// POST form. `csrf: true` adds the account's bili_jct as `csrf` (required for all write actions).
    /// Writes are not retried, so a slow response can't double-submit (e.g. coins).
    public func post(_ url: String, _ form: [String: String] = [:], sign: Sign = .none, csrf: Bool = false) async throws -> JSON {
        try await ensureBuvid()
        var p = form
        if csrf {
            guard let token = currentAccount?.csrf, !token.isEmpty else { throw BiliError.notLoggedIn }
            p["csrf"] = token
        }
        let body = sign == .app ? Signing.appSigned(p) : Signing.query(p)
        guard let u = URL(string: url) else { throw BiliError.invalidResponse }
        var request = URLRequest(url: u)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        return try await send(request, anonymous: false)
    }

    /// Raw bytes (danmaku XML, subtitles, sidx ranges…) with Bilibili headers.
    public func data(_ url: URL, headers: [String: String] = [:]) async throws -> Data {
        try await withRetry {
            var request = URLRequest(url: url)
            self.decorate(&request, anonymous: false)
            headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            let (data, response) = try await self.session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                throw BiliError.http(http.statusCode)
            }
            return data
        }
    }

    /// Fetches an exact byte range from a media CDN: one attempt, short timeout, and the response
    /// must honour the Range (206). A mirror that ignores Range would otherwise stream the whole file.
    public func rangeData(_ url: URL, _ range: ClosedRange<Int>, timeout: TimeInterval = 5) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        decorate(&request, anonymous: true)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 206 else {
            bytes.task.cancel()
            throw BiliError.http(status == 200 ? 416 : status)
        }
        var data = Data()
        data.reserveCapacity(range.count)
        for try await byte in bytes {
            data.append(byte)
            if data.count >= range.count { break }
        }
        bytes.task.cancel()
        return data
    }

    private func decorate(_ request: inout URLRequest, anonymous: Bool, as override: Account? = nil) {
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.referer, forHTTPHeaderField: "Referer")
        guard Self.sendsCookies(to: request.url) else { return }
        let cookie = cookieHeader(anonymous: anonymous, as: override)
        if !cookie.isEmpty { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
    }

    private func send(_ request: URLRequest, anonymous: Bool, as override: Account? = nil) async throws -> JSON {
        var request = request
        decorate(&request, anonymous: anonymous, as: override)
        let (data, response) = try await session.data(for: request)
        let path = request.url?.path ?? ""
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            Log.network.error("HTTP \(http.statusCode) \(path, privacy: .public)")
            throw BiliError.http(http.statusCode)
        }
        let json = try JSON(data: data)
        let code = json["code"].intValue
        guard code == 0 else {
            // QR-poll "not scanned / not confirmed" are expected states, not errors.
            if ![86039, 86090].contains(code) { Log.network.error("API \(code) \(path, privacy: .public): \(json["message"].stringValue, privacy: .public)") }
            if code == -101, !anonymous, override == nil, currentAccount != nil { onAuthFailure?() }
            throw BiliError.api(code: code, message: json["message"].string ?? json["msg"].stringValue)
        }
        return json
    }

    /// Retries transient failures (network errors, 5xx) with backoff. Risk control (HTTP 412, -352)
    /// is not retried: hammering a throttled IP only extends the lockout.
    private func withRetry<T>(_ attempts: Int = 3, _ body: () async throws -> T) async throws -> T {
        var lastError: Error = BiliError.invalidResponse
        for attempt in 0 ..< attempts {
            do {
                return try await body()
            } catch {
                lastError = error
                guard Self.isTransient(error), attempt < attempts - 1 else { throw error }
                try await Task.sleep(nanoseconds: UInt64(500_000_000 * (attempt + 1) * (attempt + 1)))
            }
        }
        throw lastError
    }

    static func isTransient(_ error: Error) -> Bool {
        if isCancellation(error) { return false }
        if let urlError = error as? URLError {
            return [.timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet]
                .contains(urlError.code)
        }
        if case let BiliError.http(status) = error { return status >= 500 }
        return false
    }

    /// URLSession reports task cancellation as `URLError(.cancelled)`, not `CancellationError`.
    public static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    // MARK: Anonymous identity & WBI keys

    private func ensureBuvid() async throws {
        guard lock.withLock({ buvid3 == nil }) else { return }
        var request = URLRequest(url: URL(string: "https://api.bilibili.com/x/frontend/finger/spi")!)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await session.data(for: request),
              let json = try? JSON(data: data),
              let b3 = json["data"]["b_3"].string
        else { return }
        let b4 = json["data"]["b_4"].string
        lock.withLock {
            buvid3 = b3
            buvid4 = b4
        }
        UserDefaults.standard.set(b3, forKey: "buvid3")
        UserDefaults.standard.set(b4, forKey: "buvid4")
    }

    /// WBI mixin key for endpoints that return non-JSON bodies (signed by the caller).
    public func wbiKeyForSigning() async throws -> String { try await wbiKey() }

    private func wbiKey() async throws -> String {
        let cached = lock.withLock { (mixinKey, mixinKeyDate ?? .distantPast) }
        if let key = cached.0, Date().timeIntervalSince(cached.1) < 3600 * 6 {
            return key
        }
        var request = URLRequest(url: URL(string: "https://api.bilibili.com/x/web-interface/nav")!)
        decorate(&request, anonymous: false)
        let (data, _) = try await session.data(for: request)
        // nav returns code -101 when logged out but still includes wbi_img.
        let img = try JSON(data: data)["data"]["wbi_img"]
        let key = Signing.mixinKey(imgURL: img["img_url"].stringValue, subURL: img["sub_url"].stringValue)
        guard !key.isEmpty else { throw BiliError.invalidResponse }
        lock.withLock {
            mixinKey = key
            mixinKeyDate = Date()
        }
        return key
    }
}

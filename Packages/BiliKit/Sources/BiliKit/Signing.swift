import CryptoKit
import Foundation

public enum Signing {
    public static func md5(_ string: String) -> String {
        Insecure.MD5.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// RFC 3986 unreserved characters; everything else is percent-encoded (uppercase hex).
    public static let unreserved: CharacterSet = {
        var set = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        set.insert(charactersIn: "-_.~")
        return set
    }()

    public static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    public static func query(_ params: [String: String]) -> String {
        params.keys.sorted().map { "\($0)=\(encode(params[$0]!))" }.joined(separator: "&")
    }

    // MARK: App (TV / iPhone) signing

    /// The app key/secret pair of Bilibili's own clients, as publicly documented by community API references
    /// (e.g. bilibili-API-collect). App endpoints (TV QR login, token refresh) only accept requests signed with one.

    public static let appKey = "5ae412b53418aac5"
    static let appSecret = "5b9cf6c9786efd204dcf0c1ce2d08436"

    public static func appSigned(_ params: [String: String], timestamp: Int = Int(Date().timeIntervalSince1970)) -> String {
        var p = params
        p["appkey"] = appKey
        p["ts"] = String(timestamp)
        p["local_id"] = p["local_id"] ?? "0"
        p["mobi_app"] = p["mobi_app"] ?? "iphone"
        let q = query(p)
        return q + "&sign=" + md5(q + appSecret)
    }

    // MARK: WBI signing (web APIs)

    private static let mixinTable = [
        46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49,
        33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40,
        61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11,
        36, 20, 34, 44, 52,
    ]

    public static func mixinKey(imgURL: String, subURL: String) -> String {
        func stem(_ url: String) -> String {
            (url as NSString).lastPathComponent.components(separatedBy: ".").first ?? ""
        }
        let raw = Array(stem(imgURL) + stem(subURL))
        guard raw.count >= 64 else { return "" }
        return String(mixinTable.prefix(32).map { raw[$0] })
    }

    public static func wbiSigned(_ params: [String: String], mixinKey: String, timestamp: Int = Int(Date().timeIntervalSince1970)) -> String {
        var p = params.mapValues { $0.filter { !"!'()*".contains($0) } }
        p["wts"] = String(timestamp)
        let q = query(p)
        return q + "&w_rid=" + md5(q + mixinKey)
    }
}

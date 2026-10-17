import Foundation

/// Lenient JSON wrapper. Bilibili's unofficial APIs are inconsistent about types
/// (numbers arrive as strings and vice versa), so we read fields through coercing accessors
/// instead of strict Codable models.
public struct JSON {
    public let raw: Any?

    public init(_ raw: Any?) {
        self.raw = raw is NSNull ? nil : raw
    }

    public init(data: Data) throws {
        self.init(try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    public subscript(key: String) -> JSON {
        JSON((raw as? [String: Any])?[key])
    }

    public subscript(index: Int) -> JSON {
        guard let arr = raw as? [Any], arr.indices.contains(index) else { return JSON(nil) }
        return JSON(arr[index])
    }

    public var exists: Bool { raw != nil }

    public var array: [JSON] { (raw as? [Any])?.map(JSON.init) ?? [] }

    public var dictionary: [String: JSON] { (raw as? [String: Any])?.mapValues(JSON.init) ?? [:] }

    public var string: String? {
        switch raw {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    public var stringValue: String { string ?? "" }

    public var int: Int? {
        switch raw {
        case let n as NSNumber: return n.intValue
        // `Int(Double)` traps on nan / inf / out of range ("1e300" from a cast request).
        case let s as String: return Int(s) ?? Double(s).flatMap { Int(exactly: $0.rounded(.towardZero)) }
        default: return nil
        }
    }

    public var intValue: Int { int ?? 0 }

    public var double: Double? {
        switch raw {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    public var doubleValue: Double { double ?? 0 }

    public var bool: Bool {
        switch raw {
        case let n as NSNumber: return n.boolValue
        case let s as String: return s == "1" || s.lowercased() == "true"
        default: return false
        }
    }
}

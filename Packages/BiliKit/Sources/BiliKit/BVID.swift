import Foundation

/// BV ↔ AV id conversion (the 2024 "BV1…" scheme with 2^51 aid space).
public enum BVID {
    private static let alphabet = Array("FcwAPNKTMug3GV5Lj7EJnHpWsx4tb8haYeviqBz6rkCy12mUSDQX9RdoZf")
    private static let xorCode: Int64 = 23_442_827_791_579
    private static let maskCode: Int64 = 2_251_799_813_685_247
    private static let maxAID: Int64 = 1 << 51

    public static func aid(from bvid: String) -> Int? {
        var chars = Array(bvid)
        guard chars.count == 12, bvid.hasPrefix("BV1") else { return nil }
        chars.swapAt(3, 9)
        chars.swapAt(4, 7)
        var value: Int64 = 0
        for c in chars.dropFirst(3) {
            guard let digit = alphabet.firstIndex(of: c) else { return nil }
            value = value * 58 + Int64(digit)
        }
        return Int((value & maskCode) ^ xorCode)
    }

    public static func bvid(from aid: Int) -> String {
        var chars = Array("BV1000000000")
        var value = (maxAID | Int64(aid)) ^ xorCode
        var i = 11
        while value > 0 {
            chars[i] = alphabet[Int(value % 58)]
            value /= 58
            i -= 1
        }
        chars.swapAt(3, 9)
        chars.swapAt(4, 7)
        return String(chars)
    }
}

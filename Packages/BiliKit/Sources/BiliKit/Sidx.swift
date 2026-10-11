import Foundation

/// Segment index parsed from an ISO-BMFF `sidx` box (ISO/IEC 14496-12 §8.16.3).
public struct SegmentIndex: Equatable, Sendable {
    public struct Segment: Equatable, Sendable {
        /// Absolute byte offset in the file.
        public var offset: Int
        public var length: Int
        public var duration: Double
    }

    public var timescale: UInt32
    public var segments: [Segment]

    public var maxDuration: Double { segments.map(\.duration).max() ?? 0 }
    public var totalDuration: Double { segments.reduce(0) { $0 + $1.duration } }

    public enum ParseError: Error {
        case notSidx
        case truncated
        /// reference_type 1 (hierarchical sidx); Bilibili never produces it.
        case nestedIndex
        case offsetOverflow
    }

    /// - Parameters:
    ///   - data: bytes of the sidx box (fetched with the representation's `index_range`).
    ///   - boxEnd: absolute file offset of the last byte of the box (the end of `index_range`).
    ///     Referenced segments start `first_offset` bytes after the box.
    public init(data: Data, boxEnd: Int) throws {
        var r = Reader(data: data)
        let size = try r.u32()
        guard try r.fourCC() == "sidx" else { throw ParseError.notSidx }
        var boxEnd = boxEnd
        // size 1 = 64-bit largesize follows; size 0 = box extends to the end of the data.
        let boxSize: Int?
        switch size {
        case 1: boxSize = Int(exactly: try r.u64())
        case 0: boxSize = data.count
        default: boxSize = Int(size)
        }
        guard let boxSize, boxSize <= data.count else { throw ParseError.truncated }
        if boxSize != data.count {
            // The fetched range may include trailing bytes; the box itself ends at boxSize.
            boxEnd = boxEnd - data.count + boxSize
        }
        let version = try r.u8()
        try r.skip(3) // flags
        _ = try r.u32() // reference_ID
        timescale = try r.u32()
        guard timescale > 0 else { throw ParseError.truncated }
        let firstOffset: UInt64
        if version == 0 {
            _ = try r.u32() // earliest_presentation_time
            firstOffset = UInt64(try r.u32())
        } else {
            _ = try r.u64()
            firstOffset = try r.u64()
        }
        try r.skip(2) // reserved
        let count = Int(try r.u16())
        guard let first = Int(exactly: firstOffset) else { throw ParseError.offsetOverflow }
        var offset = boxEnd + 1 + first
        var segments: [Segment] = []
        segments.reserveCapacity(count)
        for _ in 0 ..< count {
            let ref = try r.u32()
            let duration = try r.u32()
            _ = try r.u32() // SAP fields
            guard ref & 0x8000_0000 == 0 else { throw ParseError.nestedIndex }
            let length = Int(ref & 0x7FFF_FFFF)
            segments.append(Segment(offset: offset, length: length, duration: Double(duration) / Double(timescale)))
            offset += length
        }
        self.segments = segments
    }
}

private struct Reader {
    let data: Data
    var position = 0

    init(data: Data) {
        self.data = data
    }

    mutating func bytes(_ n: Int) throws -> [UInt8] {
        guard position + n <= data.count else { throw SegmentIndex.ParseError.truncated }
        let start = data.startIndex + position
        position += n
        return Array(data[start ..< start + n])
    }

    mutating func skip(_ n: Int) throws { _ = try bytes(n) }
    mutating func u8() throws -> UInt8 { try bytes(1)[0] }
    mutating func u16() throws -> UInt16 { try bytes(2).reduce(0) { $0 << 8 | UInt16($1) } }
    mutating func u32() throws -> UInt32 { try bytes(4).reduce(0) { $0 << 8 | UInt32($1) } }
    mutating func u64() throws -> UInt64 { try bytes(8).reduce(0) { $0 << 8 | UInt64($1) } }
    mutating func fourCC() throws -> String { String(decoding: try bytes(4), as: UTF8.self) }
}

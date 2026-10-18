import Foundation

/// HID++ 2.0 request framing, reply matching and retry policy for the t650d
/// transport. Pure logic so it is testable on Linux (spec §2).
public enum Hidpp {
    public static let longReportID: UInt8 = 0x11

    /// Delays (ms after the first attempt is due) at which a request is sent.
    /// The first request after idle is dropped or slow (spec §2.4), so a single
    /// send is never treated as failure.
    public static let retryDelaysMs = [0, 150, 500, 1000, 1500]

    /// Build a 20-byte long request: 11 <dev> <feat> <func<<4|swid> <params...>.
    public static func request(device: UInt8, feature: UInt8, function: UInt8,
                               swid: UInt8, params: [UInt8] = []) -> [UInt8] {
        var pkt: [UInt8] = [longReportID, device, feature, function << 4 | (swid & 0x0f)]
        pkt += params.prefix(16)
        return pkt + [UInt8](repeating: 0, count: 20 - pkt.count)
    }

    /// A reply echoes device, feature index and function|swid (spec §2.1).
    public static func isReply(_ r: [UInt8], to request: [UInt8]) -> Bool {
        r.count == 20 && request.count == 20 && r[0] == longReportID
            && r[1] == request[1] && r[2] == request[2] && r[3] == request[3]
    }

    /// HID++ 1.0 (0x8f) and 2.0 (0xff) error reports: 11 <dev> <8f|ff> <feat> <func|swid> <err>.
    public static func isError(_ r: [UInt8], to request: [UInt8]) -> Bool {
        r.count == 20 && request.count == 20 && r[0] == longReportID
            && r[1] == request[1] && (r[2] == 0x8f || r[2] == 0xff)
            && r[3] == request[2] && r[4] == request[3]
    }

    /// Device name (feature 0x0005) text from the accumulated payload bytes.
    public static func decodeName(_ bytes: [UInt8], count: Int) -> String {
        String(decoding: bytes.prefix(count).filter { $0 != 0 }, as: UTF8.self)
    }

    public static func isT650(name: String) -> Bool {
        name.uppercased().contains("T650")
    }
}

/// Rotating software ID (low nibble of byte 3) so a late reply to an earlier
/// request is never mistaken for the current one. Skips 0 and the ids used by
/// the kernel (0x1) and Solaar (0xf), spec §2.1.
public struct SoftwareIDs {
    private var n: UInt8 = 0
    public init() {}
    public mutating func next() -> UInt8 {
        n = n % 12 + 1
        return n + 1   // 0x2...0xd
    }
}

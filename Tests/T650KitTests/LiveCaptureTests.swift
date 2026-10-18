import XCTest
@testable import T650Kit

/// Replays the macOS live capture (hidppcore-live-capture-20261017.txt) through
/// RawReport + FrameAssembler. See hidppcore-live-capture-README.md for the
/// independently derived totals asserted here.
final class LiveCaptureTests: XCTestCase {

    /// Device index 2, feature index 15; lines are `<host_ms> <step> <20 hex bytes>`.
    func loadReports() throws -> [RawReport] {
        let url = Bundle.module.url(forResource: "fixtures/hidppcore-live-capture-20261017",
                                    withExtension: "txt")!
        let text = try String(contentsOf: url, encoding: .utf8)
        var reports: [RawReport] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            // Metadata lines (#, INFO, STATE, NOTE, ...) never have 22 numeric-led columns.
            guard cols.count == 22, Int(cols[0]) != nil else { continue }
            let bytes = cols[2...].compactMap { UInt8($0, radix: 16) }
            guard bytes.count == 20,
                  let r = RawReport(report: bytes, featureIndex: 0x0f) else { continue }
            reports.append(r)
        }
        return reports
    }

    func testNoFramesOrContactsDropped() throws {
        var assembler = FrameAssembler()
        var frames: [TouchFrame] = []
        for r in try loadReports() { if let f = assembler.add(r) { frames.append(f) } }
        XCTAssertEqual(frames.count, 3782)
        XCTAssertEqual(frames.reduce(0) { $0 + $1.contacts.count }, 7827)
        XCTAssertEqual(frames.map(\.contacts.count).max(), 9)
        XCTAssertEqual(Set(frames.flatMap { $0.contacts.map(\.fingerID) }), Set(1...10))
    }

    func testRunawayFrameIsStillCapped() {
        // Non-final reports with no end-of-frame must not accumulate forever.
        func report(eof: Bool) -> RawReport {
            var b = [UInt8](repeating: 0, count: 20)
            b[0] = 0x11; b[2] = 0x0f
            b[12] = 0x10 | (eof ? 0x01 : 0x00)   // contact A finger id 1; bit0 = end-of-frame
            b[19] = 0x01                          // 1 contact in frame; contact B empty
            return RawReport(report: b, featureIndex: 0x0f)!
        }
        var assembler = FrameAssembler()
        for _ in 0..<20 { XCTAssertNil(assembler.add(report(eof: false))) }
        let frame = assembler.add(report(eof: true))
        XCTAssertNotNil(frame)
        XCTAssertLessThanOrEqual(frame!.contacts.count, 2 * FrameAssembler.minReportCap)
    }
}

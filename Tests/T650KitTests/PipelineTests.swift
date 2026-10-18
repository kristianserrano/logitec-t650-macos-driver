import XCTest
@testable import T650Kit

/// Replays the live gesture-session capture through assembler + recogniser and
/// asserts each scripted gesture (spec §4 mapping table) is recognised.
final class PipelineTests: XCTestCase {

    struct Segment { let frames: [TouchFrame] }

    /// Segments split on wall-clock gaps >1500 ms, mirroring tools/segment.py.
    func loadSegments() throws -> [Segment] {
        let url = Bundle.module.url(forResource: "fixtures/20-gesture-session", withExtension: "txt")!
        let text = try String(contentsOf: url, encoding: .utf8)
        var segments: [[TouchFrame]] = []
        var assembler = FrameAssembler()
        var current: [TouchFrame] = []
        var started = false
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 4, let dt = Double(cols[1]) else { continue }
            let bytes = cols[2...].prefix(20).compactMap { UInt8($0, radix: 16) }
            guard bytes.count == 20,
                  let report = RawReport(report: bytes, featureIndex: 0x0f) else { continue }
            if started && dt > 1500 {
                segments.append(current); current = []
                assembler = FrameAssembler()   // idle gap implies all-up; reset lift state
            }
            started = true
            if let frame = assembler.add(report) { current.append(frame) }
        }
        if !current.isEmpty { segments.append(current) }
        return segments.map(Segment.init)
    }

    func run(_ seg: Segment) -> [GestureEvent] {
        var rec = GestureRecognizer()
        var events = seg.frames.flatMap { rec.handle($0) }
        // A segment may end with contacts still down if the terminator report was
        // the segment's last frame; ensure session close.
        events += rec.handle(TouchFrame(timestamp: (seg.frames.last?.timestamp ?? 0) &+ 8,
                                        button: false, contacts: [], lifted: []))
        return events
    }

    func testScriptedGestures() throws {
        let segs = try loadSegments()
        XCTAssertEqual(segs.count, 13)  // matches tools/segment.py on the same file
        let ev = segs.map(run)

        // seg 1: single-finger tap
        XCTAssertTrue(ev[0].contains(.tap(fingers: 1)), "\(ev[0].suffix(3))")

        // seg 3: full-area drag — moves only, net travel large
        let moves = ev[2].filter { if case .move = $0 { return true }; return false }
        XCTAssertGreaterThan(moves.count, 100)
        XCTAssertFalse(ev[2].contains { if case .swipe = $0 { return true }; return false })

        // seg 5: two-finger vertical scroll — scrolls dominated by |dy|
        func scrollTotals(_ events: [GestureEvent]) -> (dx: Double, dy: Double, n: Int) {
            var dx = 0.0, dy = 0.0, n = 0
            for e in events { if case let .scroll(x, y) = e { dx += x; dy += y; n += 1 } }
            return (dx, dy, n)
        }
        let v = scrollTotals(ev[4])
        XCTAssertGreaterThan(v.n, 20)
        XCTAssertGreaterThan(abs(v.dy), abs(v.dx) * 2, "vertical scroll: \(v)")

        // seg 6: two-finger horizontal scroll
        let hz = scrollTotals(ev[5])
        XCTAssertGreaterThan(hz.n, 20)
        XCTAssertGreaterThan(abs(hz.dx), abs(hz.dy) * 2, "horizontal scroll: \(hz)")

        // seg 7: two-finger tap
        XCTAssertTrue(ev[6].contains(.tap(fingers: 2)), "\(ev[6])")

        // seg 8: 3/4-finger swipes — at least one multi-finger swipe fired
        XCTAssertTrue(ev[7].contains { if case let .swipe(.began, f, _, _) = $0 { return f >= 3 }; return false })

        // seg 9: five fingers seen by the assembler
        let seg9 = try XCTUnwrap(segs[8].frames.map(\.contacts.count).max())
        XCTAssertEqual(seg9, 5)

        // seg 10: pinch — pinch events present
        XCTAssertTrue(ev[9].contains { if case .pinch = $0 { return true }; return false }, "\(ev[9].prefix(6))")

        // segs 12+13: physical click — button down and up both observed
        XCTAssertTrue(ev[11].contains(.buttonDown))
        XCTAssertTrue((ev[11] + ev[12]).contains(.buttonUp))
    }

    func testLiftDiffing() throws {
        // Across the whole session every fingerID that appears must eventually lift.
        let segs = try loadSegments()
        for (i, seg) in segs.enumerated() {
            let seen = Set(seg.frames.flatMap { $0.contacts.map(\.fingerID) })
            let lifted = Set(seg.frames.flatMap(\.lifted))
            // last frame's still-down contacts are allowed to remain
            let stillDown = Set(seg.frames.last?.contacts.map(\.fingerID) ?? [])
            XCTAssertEqual(seen.subtracting(lifted).subtracting(stillDown), [],
                           "segment \(i + 1): contacts vanished without a lift")
        }
    }
}

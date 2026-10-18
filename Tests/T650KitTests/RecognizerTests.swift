import XCTest
@testable import T650Kit

/// Regression tests for the recogniser misbehaviour seen on real hardware: scrolls
/// read as pinches, and click-drags that froze after a stray second contact.
final class RecognizerTests: XCTestCase {

    // MARK: synthetic frames

    private var ts = 0
    private func frame(_ pts: [(id: Int, x: Int, y: Int)], button: Bool = false) -> TouchFrame {
        ts += 8
        return TouchFrame(timestamp: ts, button: button,
                          contacts: pts.map { Contact(fingerID: $0.id, x: $0.x, y: $0.y, area: 50) },
                          lifted: [])
    }

    private func run(_ frames: [TouchFrame]) -> [GestureEvent] {
        var rec = GestureRecognizer()
        return frames.flatMap { rec.handle($0) } + rec.handle(frame([]))
    }

    private func count(_ events: [GestureEvent], _ match: (GestureEvent) -> Bool) -> Int {
        events.filter(match).count
    }
    private func isMove(_ e: GestureEvent) -> Bool { if case .move = e { return true }; return false }
    private func isScroll(_ e: GestureEvent) -> Bool { if case .scroll = e { return true }; return false }
    private func isPinch(_ e: GestureEvent) -> Bool { if case .pinch = e { return true }; return false }

    func testTwoFingerScrollWithSpacingWobbleIsNotAPinch() {
        // Both fingers glide down 6 units/frame while the spacing wobbles +-1.5%.
        var frames: [TouchFrame] = []
        for i in 0..<60 {
            let wobble = Int(9 * sin(Double(i) * 1.3))       // ~ +-1.5% of 600
            frames.append(frame([(1, 1000 - 300 - wobble, 500 + i * 6), (2, 1000 + 300 + wobble, 500 + i * 6)]))
        }
        let ev = run(frames)
        XCTAssertEqual(count(ev, isPinch), 0)
        XCTAssertGreaterThan(count(ev, isScroll), 40)
    }

    func testSymmetricSpreadIsAPinchNotAScroll() {
        var frames: [TouchFrame] = []
        for i in 0..<40 {
            frames.append(frame([(1, 1000 - 200 - i * 8, 800), (2, 1000 + 200 + i * 8, 800)]))
        }
        let ev = run(frames)
        XCTAssertEqual(count(ev, isScroll), 0)
        XCTAssertGreaterThan(count(ev, isPinch), 20)
        for case let .pinch(scale) in ev { XCTAssertGreaterThan(scale, 1) }
        XCTAssertEqual(ev.last, .pinchEnd, "a pinch must be closed when the fingers lift")
    }

    func testStrayContactDoesNotFreezeTheCursor() {
        var frames: [TouchFrame] = []
        for i in 0..<10 { frames.append(frame([(1, 500 + i * 5, 500)])) }
        // One-frame blip of a second contact (palm graze while pressing).
        frames.append(frame([(1, 550, 500), (2, 900, 900)]))
        for i in 0..<20 { frames.append(frame([(1, 555 + i * 5, 500)])) }
        let ev = run(frames)
        XCTAssertGreaterThan(count(ev, isMove), 25, "cursor must keep moving after the blip")
        XCTAssertEqual(count(ev, isPinch) + count(ev, isScroll), 0)
    }

    func testClickDragFollowsMovingFingerWithRestingThumb() {
        var frames: [TouchFrame] = []
        for i in 0..<30 {
            // Thumb (id 2) rests and holds the button; finger (id 1) drags.
            frames.append(frame([(1, 800 + i * 6, 600), (2, 300, 1500)], button: true))
        }
        let ev = run(frames)
        XCTAssertTrue(ev.contains(.buttonDown))
        let moves = ev.compactMap { e -> Double? in if case let .move(dx, _) = e { return dx }; return nil }
        XCTAssertGreaterThan(moves.count, 20)
        XCTAssertTrue(moves.dropFirst().allSatisfy { $0 > 3 }, "should follow the finger, not average with the thumb")
        XCTAssertEqual(moves.reduce(0, +), 29 * 6, accuracy: 1, "no travel lost to the slop")
    }

    func testThumbJitterAloneDoesNotDragOnClick() {
        // A click with a restless thumb and a resting finger: a click, not a drag.
        var frames: [TouchFrame] = []
        for i in 0..<30 {
            let j = (i % 2 == 0) ? 4 : -4
            frames.append(frame([(1, 800, 600), (2, 300 + j, 1500 + j)], button: true))
        }
        let ev = run(frames)
        XCTAssertEqual(count(ev, isMove), 0)
        XCTAssertTrue(ev.contains(.buttonDown))
    }

    func testThumbJitterDoesNotPullDragOffTheFinger() {
        var frames: [TouchFrame] = []
        for i in 0..<40 {
            let j = (i % 2 == 0) ? 5 : -5
            frames.append(frame([(1, 800 + i * 6, 600), (2, 300 + j, 1500 - j)], button: true))
        }
        let ev = run(frames)
        let moves = ev.compactMap { e -> (Double, Double)? in if case let .move(dx, dy) = e { return (dx, dy) }; return nil }
        XCTAssertTrue(moves.allSatisfy { $0.0 > 0 && abs($0.1) < 1 }, "only the finger moves the cursor")
    }

    func testLeftoverFingerAfterScrollDoesNotMoveCursor() {
        var frames: [TouchFrame] = []
        for i in 0..<20 { frames.append(frame([(1, 800, 500 + i * 8), (2, 1400, 500 + i * 8)])) }
        for i in 0..<15 { frames.append(frame([(1, 800 + i * 4, 660)])) }   // one finger lingers
        let ev = run(frames)
        XCTAssertEqual(count(ev, isMove), 0)
    }

    func testTwoFingerTapStillRegistersWhenFingersLandApart() {
        let ev = run([
            frame([(1, 800, 800)]),
            frame([(1, 800, 800), (2, 1200, 800)]),
            frame([(1, 800, 800), (2, 1200, 800)]),
            frame([(1, 800, 800), (2, 1200, 800)]),
            frame([(1, 800, 800), (2, 1200, 800)]),
            frame([(1, 800, 800), (2, 1200, 800)]),
        ])
        XCTAssertTrue(ev.contains(.tap(fingers: 2)), "\(ev)")
    }

    // MARK: multi-finger swipes and the three-finger drag

    private func fingers(_ n: Int, x: Int, y: Int, spacing: Int = 120) -> [(id: Int, x: Int, y: Int)] {
        (0..<n).map { (id: $0 + 1, x: x + $0 * spacing, y: y) }
    }
    private func swipes(_ ev: [GestureEvent]) -> [(GesturePhase, Int, SwipeAxis, Double)] {
        ev.compactMap { if case let .swipe(p, f, a, t) = $0 { return (p, f, a, t) }; return nil }
    }

    func testFourFingerHorizontalSwipeStreamsBeganChangedEnded() {
        var frames: [TouchFrame] = []
        for i in 0..<40 { frames.append(frame(fingers(4, x: 600 + i * 15, y: 900))) }   // fingers move right
        let sw = swipes(run(frames))
        XCTAssertEqual(sw.first?.0, .began)
        XCTAssertEqual(sw.last?.0, .ended)
        XCTAssertTrue(sw.allSatisfy { $0.1 == 4 && $0.2 == .horizontal })
        XCTAssertGreaterThan(sw.filter { $0.0 == .changed }.count, 10)
        XCTAssertGreaterThan(sw.last!.3, 300, "rightward travel is positive")
        XCTAssertEqual(sw.filter { $0.0 == .began }.count, 1)
    }

    func testFourFingerVerticalAndPinchAxes() {
        var up: [TouchFrame] = []
        for i in 0..<40 { up.append(frame(fingers(4, x: 900, y: 1800 - i * 15))) }
        let u = swipes(run(up))
        XCTAssertEqual(u.first?.2, .vertical)
        XCTAssertLessThan(u.last!.3, -300, "upward travel is negative (screen orientation)")

        var pinch: [TouchFrame] = []
        for i in 0..<40 {
            let s = 200 - i * 3     // fingers converge on the centre
            pinch.append(frame([(1, 1000 - s, 1000 - s), (2, 1000 + s, 1000 - s), (3, 1000 - s, 1000 + s), (4, 1000 + s, 1000 + s)]))
        }
        let p = swipes(run(pinch))
        XCTAssertEqual(p.first?.2, .pinch)
        XCTAssertLessThan(p.last!.3, -50, "pinching in shrinks the spread")
    }

    func testThreeFingerHorizontalIsASwipeButVerticalIsIgnored() {
        var h: [TouchFrame] = [], v: [TouchFrame] = []
        for i in 0..<30 { h.append(frame(fingers(3, x: 600 + i * 15, y: 900))) }
        for i in 0..<30 { v.append(frame(fingers(3, x: 900, y: 600 + i * 15))) }
        XCTAssertEqual(swipes(run(h)).first?.1, 3)
        XCTAssertTrue(swipes(run(v)).isEmpty)
    }

    func testFingersLiftingOneByOneAfterASwipeDoNotStartAnother() {
        var frames: [TouchFrame] = []
        for i in 0..<30 { frames.append(frame(fingers(4, x: 600 + i * 15, y: 900))) }
        // Lift to 3, then to 2, with the remaining fingers still drifting.
        for i in 0..<10 { frames.append(frame(fingers(3, x: 1050 + i * 15, y: 900))) }
        for i in 0..<10 { frames.append(frame(fingers(2, x: 1200 + i * 15, y: 900))) }
        let sw = swipes(run(frames))
        XCTAssertEqual(sw.filter { $0.0 == .began }.count, 1)
        XCTAssertEqual(sw.filter { $0.0 == .ended }.count, 1)
    }

    func testThreeFingersHeldStillBeginADragThatEndsOnLift() {
        var frames: [TouchFrame] = []
        for _ in 0..<60 { frames.append(frame(fingers(3, x: 800, y: 800))) }          // ~480 ms still
        for i in 0..<20 { frames.append(frame(fingers(3, x: 800 + i * 10, y: 800))) } // then move
        let ev = run(frames)
        let begin = ev.firstIndex(of: .dragBegan)
        XCTAssertNotNil(begin)
        XCTAssertEqual(ev.last, .dragEnded)
        let after = ev[(begin ?? 0)...]
        XCTAssertGreaterThan(count(Array(after), isMove), 10, "moves flow while dragging")
        XCTAssertTrue(swipes(ev).isEmpty, "a held drag is not a swipe")
    }

    func testQuickThreeFingerSwipeIsNotADrag() {
        var frames: [TouchFrame] = []
        for i in 0..<20 { frames.append(frame(fingers(3, x: 600 + i * 20, y: 900))) }
        let ev = run(frames)
        XCTAssertFalse(ev.contains(.dragBegan))
        XCTAssertFalse(swipes(ev).isEmpty)
    }

    func testATapWithJitterDoesNotMoveTheCursorButARealMoveStillDoes() {
        // 8 frames, +-2 unit wobble: a tap.
        var tap: [TouchFrame] = []
        for i in 0..<8 { tap.append(frame([(1, 1500 + (i % 2) * 2, 1200 - (i % 2) * 2)])) }
        let ev = run(tap)
        XCTAssertEqual(count(ev, isMove), 0)
        XCTAssertTrue(ev.contains(.tap(fingers: 1)))

        // A real move: nothing until 12 units, then the full distance is caught up.
        var mv: [TouchFrame] = []
        for i in 0..<20 { mv.append(frame([(1, 1500 + i * 5, 1200)])) }
        let moves = run(mv).compactMap { e -> Double? in if case let .move(dx, _) = e { return dx }; return nil }
        XCTAssertEqual(moves.reduce(0, +), 19 * 5, accuracy: 0.5, "no travel lost to the dead zone")
    }

    func testQuickPhysicalClickIsNotAlsoATap() {
        // Press and release within a tap's time and travel, finger lifting afterwards.
        let ev = run([
            frame([(1, 1500, 1200)]), frame([(1, 1500, 1200)]), frame([(1, 1500, 1200)]),
            frame([(1, 1500, 1200)], button: true), frame([(1, 1500, 1200)], button: true),
            frame([(1, 1500, 1200)]), frame([(1, 1500, 1200)]),
        ])
        XCTAssertTrue(ev.contains(.buttonDown))
        XCTAssertFalse(ev.contains(.tap(fingers: 1)), "the firmware already clicked; a tap would double it")
    }

    func testThumbClosingOnThreeFingersIsAPinchBothWays() {
        // Three fingers in a cluster, thumb far away; the thumb closes in (and fans out).
        func run4(inward: Bool) -> [(GesturePhase, Int, SwipeAxis, Double)] {
            var frames: [TouchFrame] = []
            for i in 0..<40 {
                let t = inward ? i : 39 - i
                frames.append(frame([
                    (1, 1000 + t * 4, 1700 - t * 2),                              // thumb moves toward the group
                    (2, 1900 - t * 1, 1000), (3, 2000 - t * 1, 1010), (4, 2100 - t * 1, 1000),   // fingers drift slightly
                ]))
            }
            return swipes(run(frames))
        }
        for inward in [true, false] {
            let sw = run4(inward: inward)
            XCTAssertEqual(sw.first?.2, .pinch, "inward=\(inward)")
        }
    }

    // MARK: press slide, edge swipe

    func testPressSlideIsUndoneButADeliberateMoveIsNot() {
        // Settled, then a slow 20-unit slide in the last frames before the button.
        var slide: [TouchFrame] = []
        for _ in 0..<20 { slide.append(frame([(1, 2000, 1500)])) }
        for i in 1...5 { slide.append(frame([(1, 2000 + i * 4, 1500)])) }
        slide.append(frame([(1, 2020, 1500)], button: true))
        let ev = run(slide)
        let down = ev.firstIndex(of: .buttonDown)!
        guard case let .move(dx, _) = ev[down - 1] else { return XCTFail("expected a compensating move before the press") }
        XCTAssertEqual(dx, -20, accuracy: 0.5)

        // A fast flick to the target followed by the press is left alone.
        var flick: [TouchFrame] = []
        for _ in 0..<20 { flick.append(frame([(1, 1000, 1500)])) }
        for i in 1...5 { flick.append(frame([(1, 1000 + i * 40, 1500)])) }
        flick.append(frame([(1, 1200, 1500)], button: true))
        let ev2 = run(flick)
        let down2 = ev2.firstIndex(of: .buttonDown)!
        if down2 > 0, case let .move(dx2, _) = ev2[down2 - 1] { XCTAssertGreaterThan(dx2, 0, "must not rewind a deliberate move") }
    }

    private func edgeEvents(_ ev: [GestureEvent]) -> [(GesturePhase, Double)] {
        ev.compactMap { if case let .edgeSwipe(p, t) = $0 { return (p, t) }; return nil }
    }

    func testTwoFingerSwipeFromRightEdgeIsAnEdgeSwipe() {
        var frames: [TouchFrame] = []
        for i in 0..<40 { frames.append(frame([(1, 2780 - i * 12, 1200), (2, 2780 - i * 12, 1350)])) }
        let ev = run(frames)
        let e = edgeEvents(ev)
        XCTAssertEqual(e.first?.0, .began)
        XCTAssertEqual(e.last?.0, .ended)
        XCTAssertGreaterThan(e.last!.1, 200, "inward travel is positive")
        XCTAssertEqual(count(ev, isScroll), 0, "an edge swipe is not a scroll")
    }

    func testTheSameSwipeStartingMidPadIsAScrollAndLeftEdgeIsNot() {
        var mid: [TouchFrame] = [], left: [TouchFrame] = []
        for i in 0..<40 { mid.append(frame([(1, 1800 - i * 12, 1200), (2, 1800 - i * 12, 1350)])) }
        for i in 0..<40 { left.append(frame([(1, 60 + i * 12, 1200), (2, 60 + i * 12, 1350)])) }
        XCTAssertTrue(edgeEvents(run(mid)).isEmpty)
        XCTAssertTrue(edgeEvents(run(left)).isEmpty)
    }

    func testVerticalTwoFingerScrollAtTheRightEdgeStaysAScroll() {
        var frames: [TouchFrame] = []
        for i in 0..<40 { frames.append(frame([(1, 2780, 600 + i * 12), (2, 2780 - 150, 600 + i * 12)])) }
        let ev = run(frames)
        XCTAssertTrue(edgeEvents(ev).isEmpty)
        XCTAssertGreaterThan(count(ev, isScroll), 20)
    }

    // MARK: live capture

    /// In the macOS capture's two-finger step, every touch is either a scroll or a
    /// pinch, never a mix (previously scrolls leaked ~40 pinch events).
    func testLiveTwoFingerTouchesAreNeverMixed() throws {
        let url = Bundle.module.url(forResource: "fixtures/hidppcore-live-capture-20261017",
                                    withExtension: "txt")!
        let text = try String(contentsOf: url, encoding: .utf8)
        var asm = FrameAssembler(), rec = GestureRecognizer()
        var scroll = 0, pinch = 0, touches = 0
        for line in text.split(whereSeparator: \.isNewline) {
            let c = line.split(separator: " ", omittingEmptySubsequences: true)
            guard c.count == 22, c[1] == "two-fingers",
                  let r = RawReport(report: c[2...].compactMap { UInt8($0, radix: 16) }, featureIndex: 0x0f),
                  let f = asm.add(r) else { continue }
            for e in rec.handle(f) { if isScroll(e) { scroll += 1 }; if isPinch(e) { pinch += 1 } }
            if f.contacts.isEmpty {
                if scroll + pinch > 0 { touches += 1; XCTAssertTrue(scroll == 0 || pinch == 0, "mixed touch: scroll=\(scroll) pinch=\(pinch)") }
                scroll = 0; pinch = 0
            }
        }
        XCTAssertGreaterThanOrEqual(touches, 4)
    }
}

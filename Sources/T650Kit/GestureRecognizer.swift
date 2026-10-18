import Foundation

/// Contact frames -> gesture intents. Pure logic, host-agnostic.
///
/// Model: a touch "session" runs from first contact down to all contacts up.
/// Behaviour follows the *settled* finger count, not the session maximum: a count
/// only takes effect once it has held for `settleFrames` frames, so fingers landing
/// a frame apart and one-frame stray contacts (a resting thumb, a palm graze while
/// pressing the button) never change the mode.
///
///  - 1 finger: pointer move
///  - 2 fingers: scroll or pinch, decided once from accumulated motion and then latched
///  - 3-4 fingers: a swipe (horizontal; vertical and pinch for 4), streamed as
///    began/changed/ended so the host can follow the fingers; or, for 3 fingers held
///    still, a drag
///  - physical button held: drag, following the contact that travels first

public enum SwipeAxis: Equatable {
    case horizontal, vertical, pinch
}

public enum GesturePhase: Equatable {
    case began, changed, ended
}

public enum GestureEvent: Equatable {
    case move(dx: Double, dy: Double)
    case scroll(dx: Double, dy: Double)
    case pinch(scale: Double)               // multiplicative per-event factor
    case pinchEnd                           // the pinch's fingers lifted or changed count
    case tap(fingers: Int)
    /// A multi-finger swipe. `travel` is the net movement since the swipe began, in
    /// device units: horizontal +right, vertical +down (screen orientation), pinch
    /// +spread-out. Always begins with `.began` (travel 0) and ends with `.ended`.
    case swipe(phase: GesturePhase, fingers: Int, axis: SwipeAxis, travel: Double)
    /// Two fingers swiping in from the right edge (Notification Center). `travel` is the
    /// inward (leftward) distance in device units.
    case edgeSwipe(phase: GesturePhase, travel: Double)
    case dragBegan                          // three fingers held still: press the button
    case dragEnded                          // ... and release it (moves arrive as `.move`)
    case buttonDown
    case buttonUp
}

public struct GestureRecognizer {
    // Tunables — calibration knobs, not device constants (spec §5.4).
    public var tapMaxDuration = 300.0        // ms, hardware-clock units
    public var tapMaxTravel = 60.0           // device units (~2.6 mm)
    public var settleFrames = 3              // frames a finger count must hold to count
    public var modeDecisionTravel = 40.0     // device units of motion before scroll/pinch/swipe is chosen
    public var dragSlop = 30.0               // device units (~1.4 mm) before a held-button drag moves
    public var dragHoldMs = 200.0            // three fingers still this long = begin a drag
    public var dragHoldSlop = 60.0           // ... "still" tolerates this much landing/resting jitter (~2.7 mm)
    public var pinchBias = 1.5               // two fingers: spread change must beat translation by this factor
    public var multiPinchBias = 0.8          // four fingers: a thumb closing on three fingers moves the centroid
                                             // almost as much as it shrinks the spacing, so the bar is lower
    public var moveSlop = 12.0               // device units (~0.5 mm) a new touch must travel before the cursor follows
    public var edgeMargin = 400.0            // two fingers starting this close to the right edge can edge-swipe
    public var clickRewindMs = 100.0         // a button press undoes slow drift this far back (press slide)
    public var clickRewindMaxTravel = 50.0   // ... but never a deliberate move longer than this
    static let padWidth = 2832.0             // spec §3.4

    private enum TwoFingerMode { case undecided, scroll, pinch, edge }
    private enum MultiMode: Equatable { case undecided, swipe(SwipeAxis), drag, ignored }

    private var session: Session?
    private var buttonHeld = false

    private struct Session {
        var startTimestamp: Int
        var settledCount = 0                 // debounced finger count
        var candidate = 0, candidateFrames = 0
        var tapFingers = 0                   // max settled count; blips never raise it
        var multiTouched = false             // 2+ fingers settled at some point
        var totalDX = 0.0, totalDY = 0.0     // whole session, for tap travel
        var twoMode = TwoFingerMode.undecided
        var pairStart: (dist: Double, mx: Double, my: Double)?   // pair geometry when the mode window opened
        var lastPairDistance: Double?
        var edgeTravel = 0.0
        var sawButton = false                // the physical button went down during this touch
        var moveOrigin: (x: Int, y: Int)?    // where the first lone finger landed
        var moveReleased = false             // it has travelled past moveSlop; the cursor now follows
        var moveLog: [(ts: Int, dx: Double, dy: Double)] = []   // recent one-finger moves, for press-slide rewind
        var multiMode = MultiMode.undecided  // 3+ fingers
        var multiStart: (cx: Double, cy: Double, spread: Double, ts: Int)?
        var multiFingers = 0
        var multiTravel = 0.0
        var multiDone = false                // a swipe/drag already ended this touch: ignore the rest
        var dragOrigin: [Int: Contact] = [:] // where each contact was when first seen under a held button
        var dragLeader: Int?
        var last: [Int: Contact] = [:]       // keyed by fingerID — ids are sparse (spec §3.5)
    }

    public init() {}

    public mutating func handle(_ frame: TouchFrame) -> [GestureEvent] {
        var events: [GestureEvent] = []

        let justPressed = frame.button && !buttonHeld
        if frame.button != buttonHeld {
            buttonHeld = frame.button
            events.append(buttonHeld ? .buttonDown : .buttonUp)
        }

        guard !frame.contacts.isEmpty else {
            if let s = session { events += endSession(s, at: frame.timestamp) }
            session = nil
            return events
        }

        var s = session ?? Session(startTimestamp: frame.timestamp)
        let rawCount = frame.contacts.count

        if frame.button { s.sawButton = true }
        if s.moveOrigin == nil, rawCount == 1 { s.moveOrigin = (frame.contacts[0].x, frame.contacts[0].y) }

        // Debounce the finger count.
        if rawCount == s.candidate { s.candidateFrames += 1 } else { s.candidate = rawCount; s.candidateFrames = 1 }
        if s.candidateFrames >= settleFrames && s.settledCount != rawCount {
            if s.twoMode == .pinch { events.append(.pinchEnd) }
            if s.twoMode == .edge { events.append(.edgeSwipe(phase: .ended, travel: s.edgeTravel)) }
            let ended = endMulti(s)
            if !ended.isEmpty { s.multiDone = true }   // fingers lifting one by one must not start another gesture
            events += ended
            s.settledCount = rawCount
            s.tapFingers = max(s.tapFingers, rawCount)
            if rawCount >= 2 { s.multiTouched = true }
            s.twoMode = .undecided
            s.pairStart = nil
            s.lastPairDistance = nil
            s.multiMode = .undecided
            s.multiStart = nil
            s.multiTravel = 0
        }

        // Per-contact motion since the last frame, for contacts tracked in both.
        var deltas: [(dx: Double, dy: Double)] = []
        for c in frame.contacts {
            if let p = s.last[c.fingerID] { deltas.append((Double(c.x - p.x), Double(c.y - p.y))) }
        }
        let tracked = deltas.count
        let dx = tracked > 0 ? deltas.reduce(0) { $0 + $1.dx } / Double(tracked) : 0
        let dy = tracked > 0 ? deltas.reduce(0) { $0 + $1.dy } / Double(tracked) : 0
        s.totalDX += dx; s.totalDY += dy

        // Pressing a clickpad makes the finger slide a little before the button flag
        // arrives, so the cursor has already wandered off the target. Undo slow drift
        // from the last `clickRewindMs`; a deliberate move (longer than the max) stays.
        if justPressed, s.settledCount == 1, !s.multiTouched {
            var rx = 0.0, ry = 0.0
            for m in s.moveLog where Double((frame.timestamp - m.ts + 65536) % 65536) <= clickRewindMs {
                rx += m.dx; ry += m.dy
            }
            if hypot(rx, ry) > 0, hypot(rx, ry) <= clickRewindMaxTravel {
                events.insert(.move(dx: -rx, dy: -ry), at: 0)   // before .buttonDown
            }
            s.moveLog = []
        }

        if buttonHeld {
            events += drag(&s, frame)
        } else {
            s.dragOrigin = [:]; s.dragLeader = nil
            switch s.settledCount {
            case 1:
                // After a multi-finger phase, a leftover finger must not move the cursor.
                if rawCount == 1, !s.multiTouched, let c = frame.contacts.first, let o = s.moveOrigin {
                    // A new touch wobbles a little as it lands and lifts; moving the cursor
                    // for that would push a tap off its target. Hold still until the finger
                    // has really travelled, then catch up the distance.
                    var mx = 0.0, my = 0.0
                    if !s.moveReleased {
                        if hypot(Double(c.x - o.x), Double(c.y - o.y)) >= moveSlop {
                            s.moveReleased = true
                            mx = Double(c.x - o.x); my = Double(c.y - o.y)
                        }
                    } else if tracked > 0 {
                        mx = dx; my = dy
                    }
                    if mx != 0 || my != 0 {
                        events.append(.move(dx: mx, dy: my))
                        s.moveLog.append((frame.timestamp, mx, my))
                        s.moveLog.removeAll { Double((frame.timestamp - $0.ts + 65536) % 65536) > 400 }
                    }
                }
            case 2 where rawCount == 2 && tracked == 2:
                events += twoFinger(&s, frame, dx: dx, dy: dy)
            case 3... where rawCount == s.settledCount && !s.multiDone:
                events += multiFinger(&s, frame, dx: dx, dy: dy)
            default:
                break
            }
        }

        s.last = Dictionary(uniqueKeysWithValues: frame.contacts.map { ($0.fingerID, $0) })
        session = s
        return events
    }

    /// Physical-click drag. A thumb pressing the button jitters and a click itself
    /// wobbles the finger, so nothing moves the cursor until one contact has travelled
    /// `dragSlop` from where it was when the button went down (a plain click stays a
    /// click). That contact then becomes the sticky leader and the others are ignored,
    /// so a restless thumb can't pull the drag around.
    private func drag(_ s: inout Session, _ frame: TouchFrame) -> [GestureEvent] {
        for c in frame.contacts where s.dragOrigin[c.fingerID] == nil { s.dragOrigin[c.fingerID] = c }

        if let id = s.dragLeader {
            if let cur = frame.contacts.first(where: { $0.fingerID == id }) {
                guard let p = s.last[id] else { return [] }
                return [.move(dx: Double(cur.x - p.x), dy: Double(cur.y - p.y))]
            }
            // Leader lifted: start over from where everything is now, with no jump.
            s.dragLeader = nil
            s.dragOrigin = Dictionary(uniqueKeysWithValues: frame.contacts.map { ($0.fingerID, $0) })
            return []
        }

        var best: (c: Contact, o: Contact, d: Double)?
        for c in frame.contacts {
            guard let o = s.dragOrigin[c.fingerID] else { continue }
            let d = hypot(Double(c.x - o.x), Double(c.y - o.y))
            if best == nil || d > best!.d { best = (c, o, d) }
        }
        guard let b = best, b.d >= dragSlop else { return [] }
        s.dragLeader = b.c.fingerID
        return [.move(dx: Double(b.c.x - b.o.x), dy: Double(b.c.y - b.o.y))]   // catch up the slop
    }

    /// Scroll vs pinch is decided once per settled two-finger period from the *net*
    /// change since the period began: scrolling moves the midpoint and keeps the
    /// spacing; pinching changes the spacing and leaves the midpoint. A per-frame
    /// ratio test can't tell them apart (spacing wobbles a few percent during every
    /// scroll), and summing per-frame changes would count that wobble as pinching.
    private func twoFinger(_ s: inout Session, _ frame: TouchFrame, dx: Double, dy: Double) -> [GestureEvent] {
        let a = frame.contacts[0], b = frame.contacts[1]
        let dist = hypot(Double(a.x - b.x), Double(a.y - b.y))
        let mx = Double(a.x + b.x) / 2, my = Double(a.y + b.y) / 2
        defer { s.lastPairDistance = dist }
        if s.pairStart == nil { s.pairStart = (dist, mx, my) }
        guard let prev = s.lastPairDistance, prev > 0 else { return [] }

        switch s.twoMode {
        case .undecided:
            let start = s.pairStart!
            let tx = mx - start.mx, ty = my - start.my
            let translation = hypot(tx, ty)
            let spread = abs(dist - start.dist)
            guard translation + spread >= modeDecisionTravel else { return [] }
            // Two fingers entering from the right edge, moving inward: Notification Center.
            if start.mx >= Self.padWidth - edgeMargin, tx < 0, abs(tx) > pinchBias * abs(ty), spread < translation {
                s.twoMode = .edge
                s.edgeTravel = -tx
                return [.edgeSwipe(phase: .began, travel: 0), .edgeSwipe(phase: .changed, travel: s.edgeTravel)]
            }
            s.twoMode = spread > pinchBias * translation ? .pinch : .scroll
            return []
        case .edge:
            s.edgeTravel = -(mx - s.pairStart!.mx)
            return [.edgeSwipe(phase: .changed, travel: s.edgeTravel)]
        case .scroll:
            return [.scroll(dx: dx, dy: dy)]
        case .pinch:
            return dist == prev ? [] : [.pinch(scale: dist / prev)]
        }
    }

    /// Three or four settled fingers. The mode is chosen once, from net movement of the
    /// centroid and of the fingers' mean distance from it:
    ///  - barely moved for `dragHoldMs` (three fingers): a drag
    ///  - spread changed more than the centroid moved (four fingers): a pinch swipe
    ///  - otherwise horizontal or vertical by the dominant axis (three fingers: only
    ///    horizontal, the others are ignored)
    private func multiFinger(_ s: inout Session, _ frame: TouchFrame, dx: Double, dy: Double) -> [GestureEvent] {
        let n = Double(frame.contacts.count)
        let cx = frame.contacts.reduce(0) { $0 + Double($1.x) } / n
        let cy = frame.contacts.reduce(0) { $0 + Double($1.y) } / n
        let spread = frame.contacts.reduce(0) { $0 + hypot(Double($1.x) - cx, Double($1.y) - cy) } / n
        if s.multiStart == nil { s.multiStart = (cx, cy, spread, frame.timestamp) }
        let start = s.multiStart!
        let tx = cx - start.cx, ty = cy - start.cy, ts = spread - start.spread
        let trans = hypot(tx, ty)

        switch s.multiMode {
        case .undecided:
            let held = Double((frame.timestamp - start.ts + 65536) % 65536)
            if s.settledCount == 3 {
                // Three fingers: resting still long enough is a drag; real movement first is
                // a swipe. Fingers shift a little as they land and settle, so "still" is
                // generous and the swipe bar is the same size.
                if max(trans, abs(ts)) < dragHoldSlop {
                    guard held >= dragHoldMs else { return [] }
                    s.multiMode = .drag
                    s.multiFingers = 3
                    return [.dragBegan]
                }
            } else {
                guard trans + abs(ts) >= modeDecisionTravel else { return [] }
            }
            guard s.settledCount <= 4 else { s.multiMode = .ignored; return [] }
            let axis: SwipeAxis?
            if s.settledCount == 4, abs(ts) > multiPinchBias * trans { axis = .pinch }
            else if abs(tx) >= abs(ty) { axis = .horizontal }
            else { axis = s.settledCount == 4 ? .vertical : nil }
            guard let a = axis else { s.multiMode = .ignored; return [] }
            s.multiMode = .swipe(a)
            s.multiFingers = s.settledCount
            s.multiTravel = Self.travel(a, tx: tx, ty: ty, ts: ts)
            return [.swipe(phase: .began, fingers: s.multiFingers, axis: a, travel: 0),
                    .swipe(phase: .changed, fingers: s.multiFingers, axis: a, travel: s.multiTravel)]
        case .swipe(let a):
            s.multiTravel = Self.travel(a, tx: tx, ty: ty, ts: ts)
            return [.swipe(phase: .changed, fingers: s.multiFingers, axis: a, travel: s.multiTravel)]
        case .drag:
            return [.move(dx: dx, dy: dy)]
        case .ignored:
            return []
        }
    }

    private static func travel(_ axis: SwipeAxis, tx: Double, ty: Double, ts: Double) -> Double {
        switch axis {
        case .horizontal: return tx
        case .vertical: return ty
        case .pinch: return ts
        }
    }

    /// Close whatever a settled multi-finger period had open.
    private func endMulti(_ s: Session) -> [GestureEvent] {
        switch s.multiMode {
        case .swipe(let a):
            return [.swipe(phase: .ended, fingers: s.multiFingers, axis: a, travel: s.multiTravel)]
        case .drag:
            return [.dragEnded]
        case .undecided, .ignored:
            return []
        }
    }

    private func endSession(_ s: Session, at timestamp: Int) -> [GestureEvent] {
        let duration = Double((timestamp - s.startTimestamp + 65536) % 65536)
        let travel = hypot(s.totalDX, s.totalDY)
        var out = endMulti(s)
        if s.twoMode == .pinch { out.append(.pinchEnd) }
        if s.twoMode == .edge { out.append(.edgeSwipe(phase: .ended, travel: s.edgeTravel)) }
        if out.isEmpty, s.tapFingers > 0, duration <= tapMaxDuration, travel <= tapMaxTravel, !s.sawButton {
            out.append(.tap(fingers: s.tapFingers))
        }
        return out
    }
}

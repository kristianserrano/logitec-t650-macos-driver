// GestureEvent -> CGEvent. The "what does it feel like" layer; every constant
// here is a tuning knob to calibrate on hardware, not derived truth.
#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import T650Kit

final class Output {
    // Device units -> pixels. The pad is 2832 units wide (~22 units/mm). Tuned on
    // hardware; override with T650_CURSOR_GAIN / T650_SCROLL_GAIN.
    var cursorGain = Output.env("T650_CURSOR_GAIN") ?? 0.7
    var scrollGain = Output.env("T650_SCROLL_GAIN") ?? 0.35
    var buttonDown = false
    /// Tap-to-click: a light tap clicks (two fingers = secondary click). Off means only
    /// the physical button clicks. T650_TAP_TO_CLICK=0 turns it off.
    let tapToClick = Output.env("T650_TAP_TO_CLICK") != 0
    var pinchAccum = 1.0
    let pinchStep = 1.15        // spread change per zoom keystroke

    /// Dual raw mode (0x15): the pad's own firmware keeps the pointer, scroll and the
    /// physical click working, so we post only what it does not provide. Tap-to-click is
    /// not among the firmware's features (observed), so taps stay ours. Posting the
    /// pointer movement as well would double every move.
    let gesturesOnly: Bool

    /// Native pinch by default; T650_PINCH=keys falls back to cmd-+ / cmd-- keystrokes.
    let nativePinch = ProcessInfo.processInfo.environment["T650_PINCH"] != "keys"
    var pinchGain = Output.env("T650_PINCH_GAIN") ?? 1.0
    private var magnifying = false
    private var dragging = false
    /// Inward travel, in device units (~18 mm), that counts as a deliberate edge swipe.
    var edgeCommit = Output.env("T650_EDGE_COMMIT") ?? 400
    private let debugEdge = ProcessInfo.processInfo.environment["T650_DEBUG"] != nil
    private var lastClick: (t: Double, p: CGPoint, state: Int64)?
    private var clickState: Int64 = 1

    /// Native swipes (T650_SWIPE=keys falls back to keyboard shortcuts on release).
    let nativeSwipe = ProcessInfo.processInfo.environment["T650_SWIPE"] != "keys"
    /// Finger travel, in device units, that equals progress 1.0. Scale with
    /// T650_SWIPE_SCALE (larger = longer swipe needed).
    var swipeScale = Output.env("T650_SWIPE_SCALE") ?? 1.0
    private var swipeSamples: [(t: Double, p: Double)] = []
    private var swipeFlavorSent = false
    private var swipeBeganPending = false

    private let keySource = CGEventSource(stateID: .privateState)

    init(gesturesOnly: Bool) { self.gesturesOnly = gesturesOnly }

    static func env(_ name: String) -> Double? {
        ProcessInfo.processInfo.environment[name].flatMap(Double.init)
    }

    func post(_ e: GestureEvent) {
        if case .pinch = e {} else { pinchAccum = 1 }
        if gesturesOnly {
            // The pad's firmware handles pointer, scroll and tap; moves are ours only
            // while a three-finger drag holds the button.
            switch e {
            case .swipe, .pinch, .pinchEnd, .dragBegan, .dragEnded, .edgeSwipe, .tap: break
            case .move where dragging: break
            default: return
            }
        }
        switch e {
        case let .move(dx, dy):
            let cur = CGEvent(source: nil)?.location ?? .zero
            let p = CGPoint(x: cur.x + dx * cursorGain, y: cur.y + dy * cursorGain)
            let type: CGEventType = buttonDown ? .leftMouseDragged : .mouseMoved
            let ev = mouse(type, at: p, button: .left)
            // Some apps read the delta fields rather than the position during a drag.
            ev?.setDoubleValueField(.mouseEventDeltaX, value: dx * cursorGain)
            ev?.setDoubleValueField(.mouseEventDeltaY, value: dy * cursorGain)
            ev?.post(tap: .cghidEventTap)
        case let .scroll(dx, dy):
            let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                             wheel1: Int32(-dy * scrollGain), wheel2: Int32(-dx * scrollGain), wheel3: 0)
            ev?.flags = []
            ev?.post(tap: .cghidEventTap)
        case .buttonDown:
            click(down: true)          // held: enables physical click-and-drag
        case .buttonUp:
            click(down: false)
        case .tap(fingers: 1):
            if tapToClick { click(down: true); click(down: false) }
        case .tap(fingers: 2):
            if tapToClick { rightClick() }
        case .tap:
            break
        case let .edgeSwipe(phase, travel):
            // Two fingers in from the right edge. macOS has no gesture event for this that
            // we can post (the Casa Touch/Options+ produced none to copy), so a committed
            // swipe toggles Notification Center instead. It can't follow the fingers.
            if debugEdge { NSLog("t650d: edge swipe %@ travel %.0f", String(describing: phase), travel) }
            if phase == .ended, travel >= edgeCommit { toggleNotificationCenter() }
        case .dragBegan:
            dragging = true
            click(down: true)
        case .dragEnded:
            dragging = false
            click(down: false)
        case let .swipe(phase, fingers, axis, travel):
            swipe(phase, fingers: fingers, axis: axis, travel: travel)
        case .pinchEnd:
            endMagnify()
        case let .pinch(scale) where nativePinch:
            magnify((scale - 1) * pinchGain)
        case let .pinch(scale):
            // Fallback (T650_PINCH=keys): the recogniser emits a tiny factor per frame; one zoom keystroke per
            // frame would be a flood. Fire a step each time the spread has changed by
            // pinchStep, so zoom speed follows how far the fingers moved.
            pinchAccum *= scale
            if pinchAccum >= pinchStep {
                key(0x18, flags: .maskCommand); pinchAccum = 1   // cmd-=
            } else if pinchAccum <= 1 / pinchStep {
                key(0x1B, flags: .maskCommand); pinchAccum = 1   // cmd--
            }
        }
    }

    /// Native magnify gesture, as recorded from a Casa Touch under Options+ with
    /// tools/eventdump.swift: CGEvent type 29, field 110 = 8 (magnify), field 132 =
    /// phase (1 began, 2 changed, 4 ended), field 113 = magnification (double). The end
    /// event carries no magnification. Undocumented fields; observed, not specified.
    private func magnify(_ amount: Double) {
        postGesture(phase: magnifying ? 2 : 1, magnification: amount)
        magnifying = true
    }

    private func endMagnify() {
        guard magnifying else { return }
        postGesture(phase: 4, magnification: nil)
        magnifying = false
    }

    private func postGesture(phase: Int64, magnification: Double?) {
        guard let ev = CGEvent(source: nil), let type = CGEventType(rawValue: 29) else { return }
        ev.type = type
        ev.setIntegerValueField(CGEventField(rawValue: 110)!, value: 8)
        ev.setIntegerValueField(CGEventField(rawValue: 132)!, value: phase)
        if let m = magnification { ev.setDoubleValueField(CGEventField(rawValue: 113)!, value: m) }
        ev.post(tap: .cghidEventTap)
    }

    /// Press the menu-bar clock, which opens (or closes) Notification Center. Uses the
    /// Accessibility API, which the daemon needs anyway for posting events. If the clock
    /// item can't be found, falls back to the Globe/Fn-N shortcut.
    func toggleNotificationCenter() {
        if AXIsProcessTrusted(),
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first {
            let root = AXUIElementCreateApplication(app.processIdentifier)
            var bar: CFTypeRef?
            if AXUIElementCopyAttributeValue(root, "AXExtrasMenuBar" as CFString, &bar) == .success, let bar = bar {
                var kids: CFTypeRef?
                AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &kids)
                for item in (kids as? [AXUIElement]) ?? [] {
                    var ident: CFTypeRef?
                    AXUIElementCopyAttributeValue(item, "AXIdentifier" as CFString, &ident)
                    if (ident as? String) == "com.apple.menuextra.clock" {
                        if AXUIElementPerformAction(item, kAXPressAction as CFString) == .success { return }
                    }
                }
            }
        }
        NSLog("t650d: clock menu item not found; trying Fn-N")
        key(0x2D, flags: .maskSecondaryFn)   // N with the Fn/Globe flag
    }

    /// Every mouse event we post carries explicit empty modifier flags. Without that,
    /// a modifier left over from a synthetic key event (cmd from a pinch) turns the
    /// next click into a cmd-click, e.g. "reveal in Finder" on a Dock icon.
    private func mouse(_ type: CGEventType, at p: CGPoint, button: CGMouseButton) -> CGEvent? {
        let ev = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button)
        ev?.flags = []
        return ev
    }

    /// Apps tell a double-click from two clicks by the click-state field, which the
    /// hardware normally sets: a second press within the double-click interval and a few
    /// pixels of the first counts as 2 (then 3). Without it, tap-tap is two single clicks.
    private func click(down: Bool) {
        buttonDown = down
        let cur = CGEvent(source: nil)?.location ?? .zero
        if down {
            let now = ProcessInfo.processInfo.systemUptime
            if let l = lastClick, now - l.t <= 0.5, hypot(cur.x - l.p.x, cur.y - l.p.y) <= 8 {
                clickState = min(l.state + 1, 3)
            } else {
                clickState = 1
            }
            lastClick = (now, cur, clickState)
        }
        let ev = mouse(down ? .leftMouseDown : .leftMouseUp, at: cur, button: .left)
        ev?.setIntegerValueField(.mouseEventClickState, value: clickState)
        ev?.post(tap: .cghidEventTap)
    }

    private func rightClick() {
        let cur = CGEvent(source: nil)?.location ?? .zero
        for t in [CGEventType.rightMouseDown, .rightMouseUp] {
            mouse(t, at: cur, button: .right)?.post(tap: .cghidEventTap)
        }
    }

    /// Native swipe, as recorded from a Casa Touch under Options+ (tools/eventdump.swift).
    /// 4 fingers = Dock swipe (CGEvent type 30, field 110 = 23), 3 fingers horizontal =
    /// navigation swipe (type 29, field 110 = 16). Both share one layout: kind in
    /// 123/165 (1 horizontal, 2 vertical, 3 pinch), phase in 132/134 (1 began, 2 changed,
    /// 4 ended), signed progress in 124 (float bits in 135), and on the first "changed"
    /// event a direction flavor in 115/164. The end event carries a final velocity in
    /// 129/130. Progress is positive for fingers LEFT / DOWN / pinch IN and negative for
    /// RIGHT / UP / spread OUT; flavor 4/8 = left/right, 2/1 = down/up, 32/16 = in/out.
    /// The 4-finger conventions were consistent across the recording; the 3-finger ones
    /// are assumed to match (the 3-finger takes were noisy).
    private func swipe(_ phase: GesturePhase, fingers: Int, axis: SwipeAxis, travel: Double) {
        guard nativeSwipe else { return swipeKeys(phase, fingers: fingers, axis: axis, travel: travel) }
        let isNav = fingers == 3
        guard isNav ? axis == .horizontal : fingers == 4 else { return }
        let type: UInt32 = isNav ? 29 : 30, hid: Int64 = isNav ? 16 : 23

        let kind: Int64, full: Double, sign: Double
        switch axis {
        case .horizontal: kind = 1; full = 1500; sign = -1    // right = negative
        case .vertical:   kind = 2; full = 1100; sign = 1     // down = positive
        case .pinch:      kind = 3; full = 600;  sign = -1    // spread out = negative
        }
        let progress = max(-1.5, min(1.5, sign * travel / (full * swipeScale)))
        let now = ProcessInfo.processInfo.systemUptime

        switch phase {
        case .began:
            // Not posted yet: the begin event must already carry the direction (see .changed).
            swipeSamples = [(now, 0)]
            swipeFlavorSent = false
            swipeBeganPending = true
        case .changed:
            if swipeBeganPending {
                // In the Casa Touch recording the begin event's progress carries the sign of
                // the whole gesture (exactly +-0.02 for pinches). A begin of 0 reads as the
                // negative direction, which is why pinch-in never triggered Launchpad.
                swipeBeganPending = false
                postSwipe(type: type, hid: hid, kind: kind, phase: 1, progress: progress >= 0 ? 0.02 : -0.02,
                          flavor: nil, velocity: nil)
            }
            swipeSamples.append((now, progress))
            swipeSamples.removeAll { now - $0.t > 0.3 }
            var flavor: Int64?
            if !swipeFlavorSent {
                swipeFlavorSent = true
                switch axis {
                case .horizontal: flavor = progress > 0 ? 4 : 8
                case .vertical:   flavor = progress > 0 ? 2 : 1
                case .pinch:      flavor = progress > 0 ? 32 : 16
                }
            }
            postSwipe(type: type, hid: hid, kind: kind, phase: 2, progress: progress, flavor: flavor, velocity: nil)
        case .ended:
            if swipeBeganPending { swipeBeganPending = false; return }   // never moved: nothing was posted
            // Commit or cancel the way the Casa Touch recording did: cancelled swipes end
            // with phase 8 and no velocity, committed ones with phase 4 and a velocity.
            // Velocity is progress per second over the last ~150 ms before release.
            let recent = swipeSamples.filter { now - $0.t <= 0.15 }
            var v = 0.0
            if let first = recent.first, let last = recent.last, last.t - first.t > 0.02 {
                v = (last.p - first.p) / (last.t - first.t)
            }
            let p = swipeSamples.last?.p ?? progress
            let commit: Bool
            if abs(p) >= 0.45 { commit = !(v * p < 0 && abs(v) >= 1.0) }   // far enough, unless flicked back
            else if abs(p) >= 0.12 { commit = v * p > 0 && abs(v) >= 1.5 } // short, but flicked onward
            else { commit = false }                                        // back near the start: cancel
            postSwipe(type: type, hid: hid, kind: kind, phase: commit ? 4 : 8, progress: p,
                      flavor: nil, velocity: commit ? v : nil)
            swipeSamples = []
        }
    }

    private func postSwipe(type: UInt32, hid: Int64, kind: Int64, phase: Int64, progress: Double,
                           flavor: Int64?, velocity: Double?) {
        guard let ev = CGEvent(source: nil), let t = CGEventType(rawValue: type) else { return }
        func f(_ n: UInt32) -> CGEventField { CGEventField(rawValue: n)! }
        ev.type = t
        ev.flags = CGEventFlags(rawValue: 0x2000_0100)          // as recorded
        ev.setIntegerValueField(f(110), value: hid)
        ev.setIntegerValueField(f(123), value: kind)
        ev.setIntegerValueField(f(165), value: kind)
        ev.setIntegerValueField(f(132), value: phase)
        ev.setIntegerValueField(f(134), value: phase)
        ev.setDoubleValueField(f(124), value: progress)
        ev.setIntegerValueField(f(135), value: Int64(Float(progress).bitPattern))
        ev.setIntegerValueField(f(136), value: 1)
        ev.setIntegerValueField(f(138), value: 3)
        // 119/139 and 120/140 read back as float32 values whose bit patterns are the
        // kind and the phase; set them that way as well.
        for n: UInt32 in [119, 139] { ev.setDoubleValueField(f(n), value: Double(Float(bitPattern: UInt32(kind)))) }
        for n: UInt32 in [120, 140] { ev.setDoubleValueField(f(n), value: Double(Float(bitPattern: UInt32(phase)))) }
        if let fl = flavor {
            ev.setIntegerValueField(f(115), value: fl)
            ev.setIntegerValueField(f(117), value: fl)
            ev.setIntegerValueField(f(164), value: fl)
        }
        if let v = velocity {
            ev.setDoubleValueField(f(129), value: v)
            ev.setDoubleValueField(f(130), value: v)
        }
        ev.post(tap: .cghidEventTap)
    }

    /// Fallback (T650_SWIPE=keys): a keyboard shortcut once the swipe ends. These can't
    /// follow the fingers or be held halfway.
    private func swipeKeys(_ phase: GesturePhase, fingers: Int, axis: SwipeAxis, travel: Double) {
        guard phase == .ended else { return }
        switch (fingers, axis) {
        case (4, .horizontal): key(travel > 0 ? 0x7C : 0x7B, flags: .maskControl)   // switch space
        case (4, .vertical):   key(travel < 0 ? 0x7E : 0x7D, flags: .maskControl)   // Mission Control / App Exposé
        case (3, .horizontal): key(travel > 0 ? 0x1E : 0x21, flags: .maskCommand)   // cmd-] / cmd-[ : forward / back
        default: break
        }
    }

    /// Key down carries the modifier; key up carries none, so the modifier can't
    /// stay asserted after the shortcut.
    private func key(_ code: CGKeyCode, flags: CGEventFlags) {
        // Real arrow keys carry the secondary-fn flag; without it the system
        // shortcuts (ctrl-arrow = switch space / Mission Control) can ignore them.
        let isArrow = (0x7B...0x7E).contains(Int(code))
        for down in [true, false] {
            let ev = CGEvent(keyboardEventSource: keySource, virtualKey: code, keyDown: down)
            ev?.flags = down ? (isArrow ? flags.union(.maskSecondaryFn) : flags) : []
            ev?.post(tap: .cghidEventTap)
        }
    }
}
#endif

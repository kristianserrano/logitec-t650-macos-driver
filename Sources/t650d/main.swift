// t650d — user-space daemon: Unifying receiver -> native macOS input events.
// Transport per T650_PROTOCOL_SPEC.md §2; decode/recognition lives in T650Kit.
//
// Not yet run end-to-end on hardware: the receiver/slot scan, retry and restore
// paths were written against the live macOS capture (device index 2, feature
// index 15, two receivers) but compiled only by macOS CI. Expect first-run fixes.

#if os(macOS)
import Foundation
import IOKit.hid
import T650Kit

let vendorID = 0x046d, productID = 0xc52b       // Unifying receiver (spec §1.1)
let maxSlot: UInt8 = 6                          // Unifying receivers pair up to 6 devices
// Raw report state (0x6100 function 2). Default 0x05 = exclusive raw + enhanced
// sensitivity (spec §2.3): the pad's pointer stops and we synthesize everything.
// Default is dual mode: 0x15 (adds bit 4, "native gestures kept alongside raw"). Tested
// on a T650: the pointer, scroll and physical click stay native and clean, and we add
// gestures and tap-to-click. T650_MODE=raw forces exclusive raw (0x05).
let dualMode = ProcessInfo.processInfo.environment["T650_MODE"] != "raw"
let rawStateEnabled: UInt8 = dualMode ? 0x15 : 0x05
let rawStateDefault: UInt8 = 0x00
let debugGestures = ProcessInfo.processInfo.environment["T650_DEBUG"] != nil
var restoring = false
let statusOnly = CommandLine.arguments.contains("--status")   // read the raw state and exit
// --set-state=15 writes that raw report state (hex), verifies it, and exits WITHOUT restoring,
// to see how the pad behaves natively in that mode. Undo with --set-state=00 (or a power cycle).
let setStateTarget: UInt8? = CommandLine.arguments.compactMap { arg -> UInt8? in
    guard arg.hasPrefix("--set-state=") else { return nil }
    return UInt8(arg.dropFirst("--set-state=".count).replacingOccurrences(of: "0x", with: ""), radix: 16)
}.first
// T650_RECORD=/tmp/frames.txt appends every raw touch report in the capture-fixture
// format (`<host_ms> live <20 hex bytes>`), so a misbehaving gesture can be replayed.
let recorder: FileHandle? = {
    guard let path = ProcessInfo.processInfo.environment["T650_RECORD"] else { return nil }
    FileManager.default.createFile(atPath: path, contents: nil)
    return FileHandle(forWritingAtPath: path)
}()

/// One HID++ request in flight. Re-sent on `Hidpp.retryDelaysMs` until a matching
/// reply or error arrives (spec §2.4: the first request after idle is dropped).
final class Transaction {
    let packet: [UInt8]
    let completion: ([UInt8]?) -> Void
    var finished = false
    init(packet: [UInt8], completion: @escaping ([UInt8]?) -> Void) {
        self.packet = packet
        self.completion = completion
    }
}

/// One matched receiver interface. Scans its slots for a T650, then owns the
/// unlock/restore sequence for it.
final class Receiver {
    unowned let daemon: Daemon
    let device: IOHIDDevice
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    var swids = SoftwareIDs()
    var inflight: Transaction?

    // Set once this receiver's T650 is claimed.
    var slot: UInt8?
    var featureIndex: UInt8?
    var savedState: UInt8?

    init(daemon: Daemon, device: IOHIDDevice) {
        self.daemon = daemon
        self.device = device
    }

    deinit { buffer.deallocate() }

    // -- transport

    private func send(_ pkt: [UInt8]) {
        var pkt = pkt
        // No interrupt OUT on this interface: SetReport goes over the control
        // endpoint, exactly what the protocol needs (spec §1.1). All requests are
        // long reports; short ones are never answered (spec §5.1).
        IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(pkt[0]), &pkt, pkt.count)
    }

    func request(slot: UInt8, feature: UInt8, function: UInt8, params: [UInt8] = [],
                 completion: @escaping ([UInt8]?) -> Void) {
        let pkt = Hidpp.request(device: slot, feature: feature, function: function,
                                swid: swids.next(), params: params)
        let t = Transaction(packet: pkt, completion: completion)
        inflight = t
        let delays = Hidpp.retryDelaysMs
        for (i, delay) in delays.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak self] in
                guard let self = self, !t.finished else { return }
                self.send(pkt)
                if i == delays.count - 1 {
                    // Last attempt: allow one more window for the reply, then give up.
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
                        self?.finish(t, nil)
                    }
                }
            }
        }
    }

    private func finish(_ t: Transaction, _ reply: [UInt8]?) {
        guard !t.finished else { return }
        t.finished = true
        if inflight === t { inflight = nil }
        t.completion(reply)
    }

    func cancelInflight() {
        inflight?.finished = true
        inflight = nil
    }

    /// Returns true if the report answered the request in flight.
    func consume(_ bytes: [UInt8]) -> Bool {
        guard let t = inflight, !t.finished else { return false }
        if Hidpp.isReply(bytes, to: t.packet) { finish(t, bytes); return true }
        if Hidpp.isError(bytes, to: t.packet) { finish(t, nil); return true }   // e.g. empty slot
        return false
    }

    // -- slot scan: find the device whose HID++ name contains "T650"

    func probe(slot s: UInt8) {
        guard s <= maxSlot, daemon.active == nil else { return }
        request(slot: s, feature: 0, function: 0, params: [0x00, 0x05]) { [weak self] reply in
            guard let self = self else { return }
            guard let nameFeature = reply?[4], nameFeature != 0 else { return self.probe(slot: s + 1) }
            self.request(slot: s, feature: nameFeature, function: 0) { countReply in
                guard let count = countReply?[4], count > 0 else { return self.probe(slot: s + 1) }
                self.readName(slot: s, feature: nameFeature, count: Int(count), bytes: []) { name in
                    NSLog("t650d: receiver slot %d: %@", s, name ?? "<no name>")
                    if let name = name, Hidpp.isT650(name: name), self.daemon.claim(self) {
                        self.unlock(slot: s)
                    } else {
                        self.probe(slot: s + 1)
                    }
                }
            }
        }
    }

    private func readName(slot s: UInt8, feature: UInt8, count: Int, bytes: [UInt8],
                          completion: @escaping (String?) -> Void) {
        if bytes.count >= count { return completion(Hidpp.decodeName(bytes, count: count)) }
        request(slot: s, feature: feature, function: 1, params: [UInt8(bytes.count)]) { [weak self] reply in
            guard let self = self, let r = reply else { return completion(nil) }
            self.readName(slot: s, feature: feature, count: count,
                          bytes: bytes + Array(r[4...]), completion: completion)
        }
    }

    // -- unlock: resolve 0x6100, save raw state, enable, verify by read-back

    private func unlock(slot s: UInt8) {
        func fail(_ why: String) {
            NSLog("t650d: slot %d unlock failed: %@", s, why)
            daemon.release(self)
        }
        request(slot: s, feature: 0, function: 0, params: [0x61, 0x00]) { [weak self] reply in
            guard let self = self else { return }
            guard let feat = reply?[4], feat != 0 else { return fail("no TOUCHPAD_RAW_XY") }
            NSLog("t650d: TOUCHPAD_RAW_XY at feature index %d, slot %d", feat, s)
            self.request(slot: s, feature: feat, function: 1) { stateReply in
                guard let state = stateReply?[4] else { return fail("getRawReportState timed out") }
                if statusOnly {
                    // Read-only: report the state and leave it exactly as found.
                    print(String(format: "t650d: slot %d raw report state is 0x%02x (%@)", s, state,
                                 state & 0x10 != 0 ? "dual raw" : state & 0x01 != 0 ? "exclusive raw" : "normal"))
                    exit(0)
                }
                if let target = setStateTarget {
                    self.request(slot: s, feature: feat, function: 2, params: [target]) { _ in
                        self.request(slot: s, feature: feat, function: 1) { verify in
                            print(String(format: "t650d: slot %d raw report state set to 0x%02x, read back 0x%02x. Left as is; undo with --set-state=00",
                                         s, target, verify?[4] ?? 0xff))
                            exit(0)
                        }
                    }
                    return
                }
                // If a previous run died with raw mode on, restore to the device default.
                self.savedState = state & 0x01 != 0 ? rawStateDefault : state
                self.slot = s
                self.featureIndex = feat
                self.request(slot: s, feature: feat, function: 2, params: [rawStateEnabled]) { _ in
                    self.request(slot: s, feature: feat, function: 1) { verify in
                        guard verify?[4] == rawStateEnabled else { return fail("unlock not confirmed") }
                        NSLog("t650d: raw reports enabled, state 0x%02x%@ (saved state 0x%02x)", rawStateEnabled, dualMode ? " (dual mode: gestures only)" : "", self.savedState ?? 0)
                        self.daemon.ready(self)
                    }
                }
            }
        }
    }

    /// Put the raw report state back, confirmed by read-back. Blocks so it can run
    /// from the signal handler right before exit. It must not depend on the main
    /// dispatch queue: this runs inside a main-queue block, so anything it queued
    /// there (the async retry timers in `request`) would never get to run.
    func restore() -> Bool {
        guard let s = slot, let feat = featureIndex, let saved = savedState else { return true }
        cancelInflight()
        for _ in 0..<3 {
            _ = blockingRequest(slot: s, feature: feat, function: 2, params: [saved])
            if blockingRequest(slot: s, feature: feat, function: 1)?[4] == saved { return true }
        }
        return false
    }

    /// Send with the same retry schedule as `request`, spinning the run loop only to
    /// receive the IOHID input callback that delivers the reply.
    private func blockingRequest(slot s: UInt8, feature: UInt8, function: UInt8,
                                 params: [UInt8] = []) -> [UInt8]? {
        var result: [UInt8]?
        let t = Transaction(packet: Hidpp.request(device: s, feature: feature, function: function,
                                                  swid: swids.next(), params: params)) { result = $0 }
        inflight = t
        defer { inflight = nil }
        var previous = 0
        for delay in Hidpp.retryDelaysMs {
            let wait = max(delay - previous, 100)   // at least 100 ms to hear a reply
            previous = delay
            send(t.packet)
            let deadline = Date().addingTimeInterval(Double(wait) / 1000)
            while !t.finished && Date() < deadline {
                CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.02, false)
            }
            if t.finished { return result }
        }
        return nil
    }
}

final class Daemon {
    /// Recogniser with the T650_DRAG_HOLD_MS override (ms three fingers must rest before a drag begins).
    static func makeRecognizer() -> GestureRecognizer {
        var r = GestureRecognizer()
        if let ms = Output.env("T650_DRAG_HOLD_MS") { r.dragHoldMs = ms }
        return r
    }
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    var receivers: [Receiver] = []
    var active: Receiver?          // the receiver whose T650 we claimed
    var streaming = false          // unlock confirmed; reports are meaningful
    var assembler = FrameAssembler()
    var recognizer = Daemon.makeRecognizer()
    let output = Output(gesturesOnly: dualMode)

    func run() {
        // Match only the vendor-defined HID++ interface of the receiver, not the
        // keyboard/mouse interfaces (spec §1.1: report IDs 0x10/0x11 live there).
        let match: [String: Any] = [
            kIOHIDVendorIDKey: vendorID,
            kIOHIDProductIDKey: productID,
            kIOHIDPrimaryUsagePageKey: 0xFF00,
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        let this = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, dev in
            Unmanaged<Daemon>.fromOpaque(ctx!).takeUnretainedValue().attach(dev)
        }, this)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, dev in
            Unmanaged<Daemon>.fromOpaque(ctx!).takeUnretainedValue().detach(dev)
        }, this)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        let r = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard r == kIOReturnSuccess else {
            fatalError("IOHIDManagerOpen: \(r) — is Input Monitoring granted?")
        }
        CFRunLoopRun()
    }

    // Re-resolve + unlock on wake/reconnect: IOHIDManager re-fires the matching
    // callback when the device re-enumerates, which starts a fresh slot scan.
    func attach(_ dev: IOHIDDevice) {
        let rx = Receiver(daemon: self, device: dev)
        receivers.append(rx)
        let this = Unmanaged.passUnretained(rx).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(dev, rx.buffer, 64, { ctx, _, _, _, _, report, len in
            let bytes = Array(UnsafeBufferPointer(start: report, count: len))
            let rx = Unmanaged<Receiver>.fromOpaque(ctx!).takeUnretainedValue()
            rx.daemon.handleReport(rx, bytes)
        }, this)
        NSLog("t650d: receiver attached, scanning slots 1-%d for a T650", maxSlot)
        rx.probe(slot: 1)
    }

    func detach(_ dev: IOHIDDevice) {
        guard let rx = receivers.first(where: { CFEqual($0.device, dev) }) else { return }
        rx.cancelInflight()
        receivers.removeAll { $0 === rx }
        if active === rx { release(rx) }
    }

    /// First receiver to find a T650 wins; others stop scanning.
    func claim(_ rx: Receiver) -> Bool {
        guard active == nil else { return false }
        active = rx
        return true
    }

    func release(_ rx: Receiver) {
        guard active === rx else { return }
        active = nil
        streaming = false
        rx.slot = nil; rx.featureIndex = nil; rx.savedState = nil
        assembler = FrameAssembler()
        recognizer = Daemon.makeRecognizer()
    }

    func ready(_ rx: Receiver) {
        guard active === rx else { return }
        streaming = true
    }

    func handleReport(_ rx: Receiver, _ bytes: [UInt8]) {
        guard bytes.count == 20, bytes[0] == Hidpp.longReportID else { return }
        if rx.consume(bytes) { return }
        guard streaming, active === rx, let slot = rx.slot, let feat = rx.featureIndex,
              bytes[1] == slot,
              let report = RawReport(report: bytes, featureIndex: feat) else { return }
        if let r = recorder {
            let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
            r.write(Data("\(Int(Date().timeIntervalSince1970 * 1000) % 100_000_000) live \(hex)\n".utf8))
        }
        guard let frame = assembler.add(report) else { return }
        for event in recognizer.handle(frame) {
            if debugGestures {
                switch event {
                case .move, .scroll: break   // too chatty
                default: NSLog("t650d: gesture %@", String(describing: event))
                }
            }
            output.post(event)
        }
    }

    /// Restore raw state (read-back verified) and exit. Runs on SIGINT/SIGTERM and
    /// after the run loop returns.
    func restoreAndExit(_ code: Int32) -> Never {
        // Ctrl-C must always end the process: a second signal, or a restore that
        // stalls, exits instead of hanging.
        if restoring { exit(1) }
        restoring = true
        DispatchQueue.global().asyncAfter(deadline: .now() + 6) {
            NSLog("t650d: WARNING restore timed out, exiting")
            exit(1)
        }
        streaming = false
        var ok = true
        for rx in receivers where rx.slot != nil { ok = rx.restore() && ok }
        NSLog(ok ? "t650d: raw state restored" : "t650d: WARNING raw state restore not confirmed")
        exit(ok ? code : 1)
    }
}

/// --synthetic=<name>: post one native swipe gesture without the pad, to check that
/// macOS reacts to the events themselves. Names: pinch-in, spread, left, right, up, down
/// (4 fingers; left/right/up/down are the direction the fingers move), 3-left, 3-right,
/// drag (the 3-finger hold-drag: press, move right, release), and edge (toggle Notification Center).
func syntheticGesture(_ name: String) {
    let out = Output(gesturesOnly: false)
    if name == "edge" || name == "notification-center" {
        // The committed right-edge swipe: toggles Notification Center.
        out.post(.edgeSwipe(phase: .began, travel: 0))
        out.post(.edgeSwipe(phase: .changed, travel: 300))
        out.post(.edgeSwipe(phase: .ended, travel: 500))
        print("t650d: posted synthetic edge swipe")
        return
    }
    if name == "drag" {
        // The 3-finger hold-drag as the daemon posts it: press at the pointer, drag ~300 px
        // right in 40 steps, release. Park the pointer on a window's title bar first.
        print("t650d: synthetic drag in 3 s; put the pointer on a window title bar")
        sleep(3)
        out.post(.dragBegan)
        for _ in 0..<40 { usleep(12_000); out.post(.move(dx: 10, dy: 0)) }   // 10 units x 0.7 gain = 7 px each
        usleep(60_000)
        out.post(.dragEnded)
        print("t650d: posted synthetic drag")
        return
    }
    let fingers: Int, axis: SwipeAxis, travel: Double
    switch name {
    case "pinch-in": (fingers, axis, travel) = (4, .pinch, -450)
    case "spread":   (fingers, axis, travel) = (4, .pinch, 450)
    case "left":     (fingers, axis, travel) = (4, .horizontal, -900)
    case "right":    (fingers, axis, travel) = (4, .horizontal, 900)
    case "up":       (fingers, axis, travel) = (4, .vertical, -700)
    case "down":     (fingers, axis, travel) = (4, .vertical, 700)
    case "3-left":   (fingers, axis, travel) = (3, .horizontal, -900)
    case "3-right":  (fingers, axis, travel) = (3, .horizontal, 900)
    default:
        print("unknown gesture '\(name)'")
        return
    }
    out.post(.swipe(phase: .began, fingers: fingers, axis: axis, travel: 0))
    for i in 1...30 {
        usleep(15_000)
        out.post(.swipe(phase: .changed, fingers: fingers, axis: axis, travel: travel * Double(i) / 30))
    }
    usleep(60_000)
    out.post(.swipe(phase: .ended, fingers: fingers, axis: axis, travel: travel))
    print("t650d: posted synthetic \(name)")
}

if let name = CommandLine.arguments.first(where: { $0.hasPrefix("--synthetic=") }) {
    syntheticGesture(String(name.dropFirst("--synthetic=".count)))
    exit(0)
}

let daemon = Daemon()
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let signalSources: [DispatchSourceSignal] = [SIGINT, SIGTERM].map { sig in
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { daemon.restoreAndExit(0) }
    source.resume()
    return source
}
daemon.run()
daemon.restoreAndExit(0)
#else
fatalError("t650d only runs on macOS; `make test` exercises the portable core")
#endif

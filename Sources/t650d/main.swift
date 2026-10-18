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
let rawStateEnabled: UInt8 = 0x05               // raw + enhanced sensitivity (spec §2.3)
let rawStateDefault: UInt8 = 0x00

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
                // If a previous run died with raw mode on, restore to the device default.
                self.savedState = state == rawStateEnabled ? rawStateDefault : state
                self.slot = s
                self.featureIndex = feat
                self.request(slot: s, feature: feat, function: 2, params: [rawStateEnabled]) { _ in
                    self.request(slot: s, feature: feat, function: 1) { verify in
                        guard verify?[4] == rawStateEnabled else { return fail("unlock not confirmed") }
                        NSLog("t650d: raw reports enabled (saved state 0x%02x)", self.savedState ?? 0)
                        self.daemon.ready(self)
                    }
                }
            }
        }
    }

    /// Put the raw report state back, confirmed by read-back. Blocks (spinning the
    /// run loop) so it can run from a signal handler right before exit.
    func restore() -> Bool {
        guard let s = slot, let feat = featureIndex, let saved = savedState else { return true }
        cancelInflight()
        for _ in 0..<3 {
            var done = false, ok = false
            request(slot: s, feature: feat, function: 2, params: [saved]) { [weak self] _ in
                self?.request(slot: s, feature: feat, function: 1) { reply in
                    ok = reply?[4] == saved
                    done = true
                }
            }
            while !done { CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.05, false) }
            if ok { return true }
        }
        return false
    }
}

final class Daemon {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    var receivers: [Receiver] = []
    var active: Receiver?          // the receiver whose T650 we claimed
    var streaming = false          // unlock confirmed; reports are meaningful
    var assembler = FrameAssembler()
    var recognizer = GestureRecognizer()
    let output = Output()

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
        recognizer = GestureRecognizer()
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
              let report = RawReport(report: bytes, featureIndex: feat),
              let frame = assembler.add(report) else { return }
        for event in recognizer.handle(frame) { output.post(event) }
    }

    /// Restore raw state (read-back verified) and exit. Runs on SIGINT/SIGTERM and
    /// after the run loop returns.
    func restoreAndExit(_ code: Int32) -> Never {
        streaming = false
        var ok = true
        for rx in receivers where rx.slot != nil { ok = rx.restore() && ok }
        NSLog(ok ? "t650d: raw state restored" : "t650d: WARNING raw state restore not confirmed")
        exit(ok ? code : 1)
    }
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

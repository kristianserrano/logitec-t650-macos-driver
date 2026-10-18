/// Reassembles multi-report frames and synthesises lift information.
/// Spec §3.1: a frame spans ceil(n/2) reports, only the last has endOfFrame.
/// Spec §3.5: there is no lift flag — contacts end by vanishing from a frame.

public struct TouchFrame: Equatable {
    public let timestamp: Int       // hardware clock, ~1 ms/unit, wraps at 65536 (spec §5.5)
    public let button: Bool
    public let contacts: [Contact]  // y already flipped to top-left origin
    public let lifted: [Int]        // fingerIDs present last frame, gone now
}

public struct FrameAssembler {
    public static let xMax = 2832   // spec §3.4
    public static let yMax = 2364

    static let minReportCap = 5

    private var pending: [Contact] = []
    private var pendingReports = 0
    private var previousIDs: Set<Int> = []

    public init() {}

    /// Feed one decoded report; returns a frame when it completes one.
    public mutating func add(_ r: RawReport) -> TouchFrame? {
        pending += r.contacts
        pendingReports += 1
        guard r.endOfFrame else {
            // ponytail: no timestamp-mismatch recovery; a dropped report loses one
            // frame (spec §4.1) and the next eof resyncs us. Cap stops runaway; it
            // follows the count field (2 contacts per report) with a floor of 5, since
            // live captures reach 9 contacts (5 reports) and the pad may support more.
            if pendingReports >= max(Self.minReportCap, (r.fingerCount + 1) / 2) {
                pending = []; pendingReports = 0
            }
            return nil
        }
        let contacts = pending.map {
            Contact(fingerID: $0.fingerID, x: $0.x, y: Self.yMax - $0.y, area: $0.area)
        }
        pending = []
        pendingReports = 0
        let ids = Set(contacts.map(\.fingerID))
        let lifted = previousIDs.subtracting(ids).sorted()
        previousIDs = ids
        return TouchFrame(timestamp: r.timestamp, button: r.button,
                          contacts: contacts, lifted: lifted)
    }
}

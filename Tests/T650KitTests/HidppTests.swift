import XCTest
@testable import T650Kit

final class HidppTests: XCTestCase {
    func testRequestLayout() {
        let r = Hidpp.request(device: 2, feature: 0x0f, function: 2, swid: 0x23, params: [0x05])
        XCTAssertEqual(r.count, 20)
        XCTAssertEqual(Array(r[0...4]), [0x11, 0x02, 0x0f, 0x23, 0x05])
        XCTAssertEqual(r[5...].reduce(0, +), 0)
    }

    func testReplyMatchingUsesSoftwareID() {
        let req = Hidpp.request(device: 2, feature: 0, function: 0, swid: 0x3, params: [0x61, 0x00])
        var reply = req; reply[4] = 0x0f
        XCTAssertTrue(Hidpp.isReply(reply, to: req))
        reply[3] = 0x04   // stale reply from a different request
        XCTAssertFalse(Hidpp.isReply(reply, to: req))
        var otherDevice = req; otherDevice[1] = 1
        XCTAssertFalse(Hidpp.isReply(otherDevice, to: req))
    }

    func testErrorReportMatching() {
        let req = Hidpp.request(device: 4, feature: 0, function: 0, swid: 0x3)
        var err = [UInt8](repeating: 0, count: 20)
        err[0] = 0x11; err[1] = 4; err[2] = 0x8f; err[3] = 0; err[4] = 0x03; err[5] = 0x09
        XCTAssertTrue(Hidpp.isError(err, to: req))
        XCTAssertFalse(Hidpp.isReply(err, to: req))
        err[4] = 0x13
        XCTAssertFalse(Hidpp.isError(err, to: req))
    }

    func testSoftwareIDsRotateAndAvoidReserved() {
        var ids = SoftwareIDs()
        var prev: UInt8 = 0
        for _ in 0..<50 {
            let id = ids.next()
            XCTAssertNotEqual(id, prev)
            XCTAssertFalse([0x0, 0x1, 0xf].contains(id))
            XCTAssertLessThan(id, 0x10)
            prev = id
        }
    }

    func testRetrySchedule() {
        XCTAssertEqual(Hidpp.retryDelaysMs, [0, 150, 500, 1000, 1500])
    }

    func testNameDecodeAndMatch() {
        let name = Hidpp.decodeName(Array("Rechargeable Touchpad T650".utf8) + [0, 0], count: 26)
        XCTAssertEqual(name, "Rechargeable Touchpad T650")
        XCTAssertTrue(Hidpp.isT650(name: name))
        XCTAssertFalse(Hidpp.isT650(name: "Wireless Mouse MX Master"))
    }
}

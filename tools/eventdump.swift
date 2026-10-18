// Guided capture of the system events a supported touchpad (Casa Touch under Logi
// Options+) produces, with every non-zero CGEvent field. Purpose: see exactly which
// native events macOS gets for each gesture, so t650d can post the same ones.
//
//   swift tools/eventdump.swift /tmp/eventdump2.txt
//
// It walks through a list of gestures. For each: press Enter, do the gesture, press
// Enter again. The output file gets "### START <label>" / "### END <label>" markers
// around the events, so nothing has to be matched up by timestamp afterwards.
//
// Listen-only: it never alters or blocks events. Needs Input Monitoring for the app
// running it (Terminal / VS Code). Pointer motion is skipped as noise.
import CoreGraphics
import Foundation

let steps = [
    "4-finger swipe LEFT (move desktop)",
    "4-finger swipe RIGHT (move desktop)",
    "4-finger swipe RIGHT, stop HALFWAY and hold 2 seconds, then finish the swipe",
    "4-finger swipe UP (Mission Control)",
    "4-finger swipe DOWN (App Exposé)",
    "4-finger PINCH in (Launchpad)",
    "4-finger SPREAD out (Show Desktop)",
    "3-finger swipe LEFT (browser back / previous page)",
    "3-finger swipe RIGHT (browser forward / next page)",
    "3-finger swipe RIGHT, stop HALFWAY and hold 2 seconds, then finish",
    "3-finger TAP AND HOLD, drag a window, release (accessibility drag)",
    "2-finger pinch OUT then IN (zoom, in Maps or Preview)",
    "2-finger DOUBLE TAP (smart zoom, in Safari on a web page)",
    "2-finger scroll down then up",
]

// `swift tools/eventdump.swift /tmp/edge.txt edge` runs only the Notification Center
// edge-swipe steps, for a quick second capture.
let edgeSteps = [
    "2-finger swipe IN from the RIGHT edge (opens Notification Center)",
    "2-finger swipe back OUT to the right (closes Notification Center)",
    "2-finger swipe IN from the RIGHT edge again, stop HALFWAY and hold 2 seconds, then finish",
    "2-finger swipe IN from the RIGHT edge, stop halfway, then push BACK out and release (cancel)",
]
// `... /tmp/drag.txt drag`: the 3-finger accessibility drag. Enable "Accessible drag and
// drop" for the touchpad in Options+ first (trigger: three-finger tap and hold).
let dragSteps = [
    "3-finger TAP AND HOLD on a window's title bar for 1 second, drag it a short way, release",
    "Same again, but hold for 3 seconds before moving",
    "3-finger quick TAP only (no hold, no move)",
    "3-finger tap, then immediately put 3 fingers down again and HOLD, drag, release",
]
let activeSteps: [String] = {
    guard CommandLine.arguments.count > 2 else { return steps }
    switch CommandLine.arguments[2] {
    case "edge": return edgeSteps
    case "drag": return dragSteps
    default: return steps
    }
}()

let skip: Set<UInt32> = [5, 6, 7, 27]   // mouse moved / dragged
let start = Date()
let out: FileHandle = {
    let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/eventdump.txt"
    FileManager.default.createFile(atPath: path, contents: nil)
    return FileHandle(forWritingAtPath: path)!
}()
let writer = DispatchQueue(label: "eventdump.writer")

func write(_ line: String) {
    let t = String(format: "%8.3f", Date().timeIntervalSince(start))
    writer.sync { out.write(Data("\(t) \(line)\n".utf8)) }
}

let callback: CGEventTapCallBack = { _, type, event, _ in
    guard !skip.contains(type.rawValue) else { return Unmanaged.passUnretained(event) }
    var fields: [String] = []
    for n in 0..<256 {
        let f = CGEventField(rawValue: UInt32(n))!
        let i = event.getIntegerValueField(f), d = event.getDoubleValueField(f)
        if i != 0 || d != 0 { fields.append("f\(n)=\(i)" + (d != 0 && Double(i) != d ? "/\(d)" : "")) }
    }
    write("type=\(type.rawValue) flags=0x\(String(event.flags.rawValue, radix: 16)) \(fields.joined(separator: " "))")
    return Unmanaged.passUnretained(event)
}

guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                  options: .listenOnly, eventsOfInterest: ~0,
                                  callback: callback, userInfo: nil) else {
    fatalError("could not create the event tap: grant Input Monitoring to this terminal")
}
CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

// The prompts run on a background thread; the event tap needs the main run loop.
DispatchQueue.global().async {
    print("Guided capture: \(activeSteps.count) gestures. Enter = start, do the gesture, Enter = done.")
    print("Type 's' + Enter at the first prompt to skip a gesture you can't do.\n")
    for (i, label) in activeSteps.enumerated() {
        print("[\(i + 1)/\(activeSteps.count)] \(label)\n    Enter to START (s to skip) > ", terminator: "")
        fflush(stdout)
        if readLine()?.lowercased() == "s" { continue }
        write("### START \(label)")
        print("    ...do it now, then press Enter > ", terminator: "")
        fflush(stdout)
        _ = readLine()
        write("### END \(label)")
    }
    print("\nDone. Output is in the file you named. Send it over.")
    exit(0)
}
CFRunLoopRun()

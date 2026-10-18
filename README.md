# logitec-t650-macos-driver

A user-space driver that gives the Logitech T650 touchpad (Unifying receiver) native-feeling
gestures on macOS: pinch, rotate, smart zoom, 3- and 4-finger swipes, tap-to-click, a
3-finger drag and a right-edge swipe for Notification Center.

Without it the T650 is a plain mouse on macOS. With it, `t650d` switches the pad into a raw
touch mode, recognises gestures from the finger data, and posts the same system events the
Logitech Casa Touch produces under Logi Options+ (which does not support the T650).

**Status:** works on the author's machine (macOS 15.8, one T650 behind a Unifying receiver).
Gesture events use undocumented macOS event fields, copied from recordings rather than a
specification, so a macOS update could change them. See [Limits](#limits).

## Build and run

```sh
swift build
.build/debug/t650d 2>&1 | tee -i /tmp/t650d.log
```

Grant the app you run it from (Terminal, iTerm, VS Code):

- **Input Monitoring**, to read the receiver. Without it `IOHIDManagerOpen` fails.
- **Accessibility**, to post mouse, key and gesture events.

Stop with Ctrl-C: it puts the pad back to normal mode and then exits. Use `tee -i`, otherwise
Ctrl-C also kills `tee` and the "raw state restored" line is lost. Quit Logi Options+ if it
manages the same receiver; coexistence is untested.

The portable core builds and tests on Linux (`make test` runs it in Docker); the daemon is
macOS-only.

```sh
swift test
```

## Gestures

| Gesture | Result |
|---|---|
| 2-finger pinch | Native zoom |
| 2-finger rotate | Native rotate |
| 2-finger double tap | Smart zoom |
| 2-finger tap | Secondary click |
| 2-finger swipe in from the right edge | Opens Notification Center |
| 4-finger swipe left/right | Move between desktops, follows your fingers |
| 4-finger swipe up/down | Mission Control / App Exposé |
| 4-finger pinch / spread | Launchpad / Show Desktop |
| 3-finger swipe left/right | Browser back / forward |
| 3 fingers held still, then move | Drag (accessibility-style drag) |
| 1-finger tap | Click |

The pad's own pointer, scrolling and physical click are left alone in the default mode.

## Modes

- **Dual raw (default).** Raw state `0x15`: the pad keeps its own pointer, scroll and physical
  click, and `t650d` adds gestures and tap-to-click. Clean clicks, no cursor heuristics.
- **Exclusive raw.** `T650_MODE=raw` (state `0x05`): the pad's pointer stops and `t650d`
  synthesises pointer motion, clicks and scrolling itself. Needed only if dual mode misbehaves;
  pointer feel then depends on `T650_CURSOR_GAIN` and `T650_SCROLL_GAIN`.

Without the daemon running the pad is in normal mode (state `0x00`).

## Options

Environment variables, set in front of the command, e.g. `T650_DRAG_HOLD_MS=100 .build/debug/t650d`.

| Variable | Default | Meaning |
|---|---|---|
| `T650_MODE` | dual | `raw` selects exclusive raw mode |
| `T650_TAP_TO_CLICK` | on | `0`: only the physical button clicks |
| `T650_SMART_ZOOM` | on | `0`: no smart zoom; a 2-finger tap secondary-clicks immediately instead of after 0.35 s |
| `T650_DRAG_HOLD_MS` | 50 | How long 3 fingers rest before a drag begins |
| `T650_SWIPE_SCALE` | 1.0 | Larger means longer swipes are needed |
| `T650_EDGE_COMMIT` | 400 | Inward travel (device units, ~18 mm) that counts as an edge swipe |
| `T650_PINCH_GAIN`, `T650_ROTATE_GAIN` | 1.0 | Zoom / rotate speed |
| `T650_PINCH=keys` | native | Pinch as Cmd-+ / Cmd-- keystrokes |
| `T650_SWIPE=keys` | native | Swipes as keyboard shortcuts on release |
| `T650_CURSOR_GAIN`, `T650_SCROLL_GAIN` | 0.7, 0.35 | Raw mode only |
| `T650_DEBUG` | off | Log every recognised gesture |
| `T650_RECORD=path` | off | Write the raw touch reports to a file in the capture format, to replay a problem |

Command-line flags:

- `--status`: read the pad's raw state (`normal`, `dual raw` or `exclusive raw`) and exit.
- `--set-state=NN`: write a raw state (hex) and exit without restoring, to try the pad in that
  mode with no driver. Undo with `--set-state=00`.
- `--synthetic=NAME`: post one gesture without the pad, to check macOS reacts to the events.
  Names: `pinch-in`, `spread`, `left`, `right`, `up`, `down`, `3-left`, `3-right`, `edge`,
  `drag`, `smart-zoom`, `rotate`, `rotate-ccw`.

## Limits

- **Undocumented events.** Pinch, rotate, smart zoom and the swipes post `CGEvent` types and
  fields that Apple does not document. They were recorded from a Casa Touch with
  `tools/eventdump.swift` and verified on one macOS version (15.8). Re-run the guided capture
  if a macOS update breaks a gesture.
- **Edge swipe is a toggle.** Neither macOS nor the Casa Touch exposes a postable event for it,
  so a committed swipe presses the menu-bar clock through the Accessibility API (Fn-N as a
  fallback). It cannot follow your fingers and a swipe back out does not close it.
- **Firmware scrolling.** In dual mode the pad's own horizontal scroll still happens during an
  edge swipe, so the page under the pointer may pan slightly.
- **Tap timing.** A single 2-finger tap waits 0.35 s so a second tap can become smart zoom.
- **One pad.** The first T650 found on any attached receiver (slots 1-6) is used.
- **Untested:** an unclean exit leaves the pad in dual mode until the next run or a power
  cycle (`--status` shows it); unlock after sleep or power-cycle is not exercised.

## Layout

- `Sources/T650Kit`: portable core. Report decoder, frame assembler, gesture recogniser, HID++
  helpers. Builds on Linux and macOS.
- `Sources/t650d`: the macOS daemon. IOHIDManager transport, slot scan, unlock/restore, event
  output.
- `Tests/T650KitTests`: unit tests, including replays of the live captures in `fixtures/`.
- `T650_PROTOCOL_SPEC.md`: the wire protocol, from live captures.
- `captures/`, `tools/`: Linux captures and the capture scripts. `tools/eventdump.swift` is the
  guided recorder for the system events a supported touchpad produces:

  ```sh
  swift tools/eventdump.swift /tmp/out.txt          # all gestures
  swift tools/eventdump.swift /tmp/out.txt edge     # also: drag, rotate
  ```

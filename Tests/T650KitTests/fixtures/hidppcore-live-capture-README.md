# hidppcore-live-capture-20261017.txt

Raw `TOUCHPAD_RAW_XY` (0x6100) reports from a real T650 on **macOS**, captured with
`tools/t650-raw-capture` in HidppCore (`kristianserrano/HidppCore`, branch
`feature/t650-raw-capture`). Raw state was set to `0x05` for the capture and restored to `0x00`
(read-back verified, see the `RESTORE` line).

Format (different from `20-gesture-session.txt`):
- `#`, `INFO`, `STATE`, `SHORT`, `ENABLE`, `RESTORE`, `NOTE` lines are metadata.
- Every other line: `<host_ms> <step> <20 hex bytes>` (a full HID++ long report).
- Device index 2 (receiver slot 2), feature index 15. Steps: idle-1, one-finger-drag,
  one-finger-tap, two-fingers, five-fingers, ten-fingers, hard-press, physical-click, idle-2.

Layout (see T650_PROTOCOL_SPEC.md section 3.2): ts = bytes 4-5 BE; contact A = bytes 6-12,
contact B = bytes 13-19. **Finger id = high nibble of byte 12 / byte 19.** Byte 12 low nibble =
flags (bit0 end-of-frame, bit1 spurious, bit2 button); byte 19 low nibble = contacts in frame.

Facts established from this file (independently re-derived): 3,782 frames, 7,827 contacts; finger
ids 1-10; frame contact count reaches **9** (so do not cap at 5); z always 0; area 0-168; timestamp
restarts at 7 on a new touch-down (it is not a free-running clock). The ten-finger and five-finger
steps used real hands, so counts are lower bounds, not device limits.

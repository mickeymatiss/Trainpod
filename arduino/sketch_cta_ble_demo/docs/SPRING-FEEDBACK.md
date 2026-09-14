# Physical push-in tab

The bottom-right black tab defaults to width 50 px, height 17 px, radius 7 px,
and travel depth 10 px. Button-down pushes it up over 350 ms; release retracts
it over 120 ms. It stays held while pressed and reverses from its current
position. The cached backdrop avoids clearing footer content visibly.

The physical button or `spring testdown` keeps the screen awake until release.
The normal two-second BLE hold and single/double-tap navigation remain intact.
A button held at boot receives a debounced down edge. Serial simulation does
not trigger navigation or the BLE hold action.

Commands, at 115200 baud with newline endings:

- `spring on/off`, `spring testdown/testup`
- `spring width 4..64`, `spring height 3..32`, `spring depth 1..11`
- `spring radius 0..12`
- `spring pressms 10..500`, `spring releasems 10..1000`
- `spring status/help/reset`, `spring debug on/off` (visible with `log debug`)

Geometry must satisfy height >= depth + radius, depth < height, and radius
<= half the width and height. All settings are RAM-only. Disabling/resetting
or choosing a preset clears a simulated hold. Real button edges take over from
simulation. Existing full-screen composition and a small cached tab region
are reused; held/retracted states do not repaint without a content change.

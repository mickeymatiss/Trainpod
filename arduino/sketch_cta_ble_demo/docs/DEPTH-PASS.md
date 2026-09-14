# Subtle screen and numeral depth

The existing renderer now adds a 1 px inner lip before content: top/left use the theme background scaled to 90% brightness, bottom/right to 105% with RGB565 saturation. No fixed black/white colors, extra timers, blur, or new rendering subsystem. The footer restores its lip whenever it is already repainted, and the tab's cached background includes that structural edge.

ETA and distance numbers get one additional glyph copy, offset +1,+1 and darkened 30% from their actual full-strength color. The primary glyph follows on top. ETA layers use the same fade opacity toward the gauge background, reaching exactly background at zero. The existing numeric-field clipping and bezel preservation remain in effect. Distance depth is composed with its gauge and follows its stable transition behavior. Station, direction, route, destination and unit labels retain single-layer rendering.

Serial commands, RAM-only:

```text
lip on
lip off
lip shadow 10
lip highlight 5
depth on
depth off
depth darken 30
depth x 1
depth y 1
```

Shadow range 0–20%; highlight 0–10%; depth darkening 0–60%; offsets 0–2 px. Both treatments default on. `status` reports them; `reset` restores defaults; `all on/off` includes them. Effects are applied during existing region draws only. RGB565 quantization may make small lip adjustments invisible on very dark themes.

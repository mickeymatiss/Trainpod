# Retained TrainPod display controls

Serial: 115200 baud, newline-delimited commands. Settings are RAM-only.
`help` and `status` show current settings. `reset` restores bloom, depth, lip,
bezel and spring defaults. `receiver reset` resets transport statistics.
Night and transition settings have separate controls.

| Treatment | Default | Controls |
| --- | --- | --- |
| Push-in tab | On; width 50, height 17, depth 10, radius 7; press 350 ms, release 120 ms | `spring on/off`, `spring testdown/testup`, `spring status/help/reset`; geometry/timing controls in SPRING-FEEDBACK.md |
| ETA bloom | On; radius 1, intensity 18%, copies 4, offsets 0/0 | `bloom on/off`, `bloom radius 0..3`, `bloom intensity 0..50`, `bloom copies 4/8`, `bloom x -3..3`, `bloom y -3..3` |
| Screen lip | On; shadow 10%, highlight 5% | `lip on/off`, `lip shadow 0..20`, `lip highlight 0..10` |
| Numeral depth | On; darken 30%, offset +1/+1 | `depth on/off`, `depth darken 0..60`, `depth x 0..2`, `depth y 0..2` |
| Uniform bezels | On for ETA, distance and route; thickness 2, brightness 50%, contrast 40% | `bezel on/off`, `bezel thickness 1..3`, `bezel brightness 0..100`, `bezel contrast 0..100`, `bezel eta 0/1`, `bezel distance 0/1`, `bezel route 0/1` |
| Stable distance | On | `stable on/off` |

`all on/off` toggles spring, bloom, bezels, lip and depth. It does not change
stable-distance, transition or night settings. `demo clean`, `demo retro` and
`demo weird` reset spring and effect settings; Clean disables bloom, Retro
sets bloom intensity to 15%, and Weird sets bloom radius 3 and intensity 40%.
Demo presets preserve current bezel and transition settings.

Successful visual edits request one composed redraw. ETA digits keep their
uniform fit and rim cache during fades. There is no periodic scan rendering,
lens distortion or randomized/deterministic variation treatment in this version;
the corresponding experimental commands have been removed.

## Navigation and refresh

`transition on/off`, `transition status/help`, `transition outms 40..200`,
`transition inms 40..250`, `transition stagger 0..80`, `transition gap 0..80`.
Defaults: 200 ms out, 200 ms in, 75 ms stagger, 75 ms gap: 775 ms total across
header, three rows and distance. Timing edits apply to the next transition.
Unchanged fields remain steady. Same-view data refreshes use changed-ETA fades
rather than navigation transitions. The first arrival page dwells eight seconds;
later pages dwell six seconds. Empty rows retain their instrument frames.

Builds, device testing and flashing are left to the user.

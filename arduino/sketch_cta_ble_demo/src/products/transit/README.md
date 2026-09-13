# Transit product

The product composes reusable device services in `src/platform` into Trainpod.
Arduino compiles all `.cpp` files recursively below `src`; no project file or
manual file list is needed. Open the sketch's root `.ino` in Arduino IDE.

| Folder | Responsibility |
| --- | --- |
| `app/` | Setup, main loop, and wiring between input, BLE, rendering, and power |
| `data/` | Arrival board models and TP2 payload decoding/validation |
| `input/` | Single/double tap recognition; application code handles the BLE hold |
| `ble/` | Transit-specific BLE protocol integration and refresh policy |
| `ui/` | Arrival display rendering and selective updates |
| `ui/animation/` | ETA fades, platform transitions, and startup animation |
| `ui/theme/` | Persistent palette implementation and local include bridge |
| `ui/fonts/` | Bundled generated font headers |

The root `pallete.h` remains the actual palette declaration so it is visible as
an Arduino IDE tab. `ui/theme/pallete.h` forwards to it. Keep font licensing
files at sketch root. Fonts are assets; edit the renderer rather than font data
for layout changes.

Keep platform code free of transit-product dependencies. Protocol changes
belong in `ble`, payload parsing in `data`, and visual changes in `ui`.
`app/TransitApp.cpp` owns hardware side effects and calls into those components.

This pass only reorganizes files and references. No compile, tests, or upload
were run.

### Display typography

Labels use upright Barlow Condensed at 24px (station/direction/route), 20px
(destination), 16px (distance unit), and 12px (status). Station names and route abbreviations use SemiBold;
directions and other labels use Regular. Italic assets remain available. Digits within labels also use Barlow.
Only ETA and distance values retain the existing bold-italic numeral fonts.

The original Regular, SemiBold, Bold, and Italic TTF files live in `tools/fonts/` at the sketch root. Regenerate the
GFX headers with Pillow installed:

```sh
python3 tools/generate_barlow_font.py tools/fonts/BarlowCondensed-Regular.ttf src/products/transit/ui/fonts
python3 tools/generate_barlow_font.py tools/fonts/BarlowCondensed-SemiBold.ttf src/products/transit/ui/fonts
```

Barlow is SIL OFL 1.1. Ship `BARLOW-CONDENSED-LICENSE.txt` with the firmware's
third-party notices. Existing numeral fonts retain their separate licenses.

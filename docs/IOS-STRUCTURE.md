# iOS source organization

`Trainpod/TrainpodApp.swift`, `Info.plist`, and assets stay at the app root.
`Trainpod/Platform` remains shared infrastructure for BLE, transport, and diagnostics.
Transit-specific code lives in `Trainpod/Products/Transit`:

| Folder | Contents |
| --- | --- |
| `App/` | Root tabs and long-lived service composition (`BLERuntime`) |
| `Data/` | Station repository, shared cache, and live transit provider |
| `Data/API/` | CTA requests and private response decoding types |
| `Data/Models/` | Station, arrival, and direction value types |
| `Location/` | Transit location acquisition and permissions |
| `BLE/` | Product BLE configuration, refresh handling, and payload encoding |
| `UI/Nearby/` | Nearby screen and its view model |
| `UI/Diagnostics/` | Product BLE test screen |
| `Themes/Model/` | Theme values, preset catalog, and color conversion |
| `Themes/` | Theme editing, persistence, live-update and ACK controller |
| `Themes/Views/` | Theme picker, shared preview, and live color section |

The Xcode project uses a filesystem-synchronized `Trainpod` root. Swift files
under these folders are discovered automatically within the same app module;
there are no per-file project entries or relative Swift imports to update.
`ThemePreview` is module-internal so both theme screens can share it.

Keep hardware-independent infrastructure in Platform and product composition
in App. Theme visual changes belong in Themes/Views; BLE payload formatting
belongs in the product's BLE folder, not shared transport.

This organization pass preserves type names and behavior. No build or tests
were run. The formatter command example in tests/PLATFORM-PAGES.md uses the new
paths.

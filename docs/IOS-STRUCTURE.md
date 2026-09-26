# iOS source organization

`Trainpod/TrainpodApp.swift`, `Info.plist`, and assets stay at the app root.
`Trainpod/Platform` remains shared infrastructure for BLE, transport, and diagnostics.
Transit-specific code lives in `Trainpod/Products/Transit`:

| Folder | Contents |
| --- | --- |
| `App/` | Root tabs and long-lived service composition (`BLERuntime`) |
| `Data/` | Station repositories and shared provider contracts (Data/LiveTransitProvider.swift); active provider implementation lives in Serving |
| `Data/API/` | CTA requests and private response decoding types |
| `Data/Models/` | Station, arrival, and direction value types |
| `Location/` | Transit location acquisition and permissions |
| `Serving/` | Active LiveTransitProvider, cloud-first coordination and direct-source fallback |
| `Debug/` | Mixed scope: comparison models and LegacyArrivalAdapter are used by release serving; simulator/comparison screens use DEBUG guards |
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

## Active serving and freshness

`BLERuntime` and the Nearby view model create `LiveTransitProvider` from
`Serving/CloudLiveTransitProvider.swift`. `TransitServingCoordinator` attempts
cloud serving for CTA, MTA, BART and MBTA. CTA/MTA have direct legacy fallback;
BART/MBTA do not (`TransitSystemID.supportsLegacySource`). Direct comparison
work also uses `LegacyTransitArrivalSource`, `Debug/LegacyArrivalAdapter.swift`
and `Debug/ArrivalComparisonModels.swift`; those files are not DEBUG-only.
Directory names alone do not establish release reachability.

Freshness is not one shared cache duration:

- `CloudTransitArrivalSource` reuses a fetched snapshot for up to 20 seconds but
  requires its source age to be less than 180 seconds; reuse does not reset source time.
- `LocationService.recentLocation` accepts a nonnegative location age under 30
  seconds and horizontal accuracy 0–1000 metres.
- Nearby UI polls every 60 seconds, retaining loaded arrivals and their original
  updated time after periodic errors. Initial errors also leave a periodic attempt
  scheduled. User refresh is immediate; teardown cancels its loop (F13).
- Firmware `RefreshFlow` uses 60 seconds since valid data application, plus explicit
  wake demand. The update episode is bounded at 45 seconds with the existing
  five-second retry/cooldown rules. These clocks do not establish that an old
  retained board is current upstream data.

See [test scope](../tests/README.md) and the source-checked
[firmware overview](../arduino/sketch_cta_ble_demo/README.md).

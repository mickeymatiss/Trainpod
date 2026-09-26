# Test inventory — release 1 characterization pass

Baseline production commit: `8fc1dad41dc903d9c0865427cd33942caf3fe1fe` (`release 1`). Production code is unchanged. PASS means the host harness compiled and ran with assertions enabled. MANUAL and COMPILED ONLY are not passes. This is an inventory of checked-in harnesses, not a claim of full app/firmware build coverage.

## Existing harnesses

| Test | Previous State | Current State | Behavior Protected | Notes |
|---|---|---|---|---|
| `tests/platform_formatter_test.swift` | Compile failed: obsolete model/error shims and route styling dependency | PASS | Station-major order, direction ordering, four platform cap, current nine-arrival capacity, distances and payload limit | Now uses real production DTOs and current formatter dependencies; expected arrival count updated from obsolete three-per-platform expectation. |
| `tests/mta_arrivals_test.swift` | Built with current dependencies; assertion failed on old serialized Eastbound/Westbound labels | PASS | Protobuf malformed input, trip filtering, directions, exact stops, deduplication, next-nine selection, feed age and TP2 | Model destinations remain Northbound/Southbound; serialized directions correctly expect North/South/East/West. No live input is needed. |
| `tests/transit_manifest_test.swift` | Compile failed: TransitAgency shim missing BART/MBTA; external fixtures required | PASS | Per-system cache/ETag, 304, offline reuse, invalid replacement, disk failure, city-switch race and HTTP status handling | Uses production system mapping and four small checked-in synthetic manifests. Existing small fake client/URLProtocol retained. |
| `tests/mta_live_smoke.swift` | Not run during audit; requires live network | COMPILED ONLY | Optional live Times Square catalog/feed smoke | Compiles with the common host dependencies. Not run in the offline suite; opt in with `--live`. |
| `arrival_screen_test.cpp` | Assertion failed: missing TP2 checksum footer and obsolete 5s timing expectations | PASS | Decoder rejection/retention; standard/compact page counts, 8s/6s dwell, replacement, stale age, delayed ticks and wrap | Tests current state model, not physical rendering. |
| `button_navigation_test.cpp` | PASS | PASS, unchanged | Single/double timing, no extra single, reset, wrap and station/platform navigation | Existing behavioral anchor retained. |
| `eta_fade_test.cpp` | PASS | PASS, unchanged | Fade timing, unchanged values, invisible swap, retarget and wrap | Existing pure state-machine test retained. |
| `eta_render_test.cpp` | Host compile failed: missing current Arduino dependencies; obsolete screen APIs and pixel assumptions | MANUAL — M8 | Intended protection: unchanged updates, ETA dirty regions, digit fit, footer isolation, transitions | Legacy source/stub retained as historical evidence. Repair would need substantial platform simulation; no fake TFT/task architecture added. Explicitly excluded from host pass count. |
| `mta_arrivals_contract_test.cpp` | Compiled only; generated Swift fixture absent, old direction expectations | PASS | Actual Swift-generated MTA bytes accepted by firmware, route/color/counts, station navigation and corruption rejection | Runner always generates input with repaired Swift harness first. |
| `mta_station_test.cpp` | PASS | PASS, unchanged | MTA station payload, navigation, empty direction and corruption | Existing checks retained. |
| `platform_dip_test.cpp` | Compile failed: removed opacity/swaps/step interface | PASS | Current header fade, shared content/light reveal, six slots, retarget, disable/cancel and wrap | Obsolete 175ms whole-screen expectation replaced by current 200/75/200ms header and 300ms content reveal. |
| `platform_pages_test.cpp` | Compile failed: removed distanceMiles field | PASS | One-to-four platforms, station identity, selection preservation/reset, legacy records, malformed distances and Swift P1 frame | Uses distanceValue; generated fixture expects six retained arrivals per platform rather than three visible arrivals. |
| `receiver_test.cpp` | PASS | PASS, unchanged | SLIP fragmentation, escaping, CRC, limits, sequence/wrap, timeout/recovery, coalescing, disconnect | Links existing BLETestReceiver.cpp. |
| `refresh_flow_test.cpp` | Compile failed: removed poll API and obsolete timeout suppression | PASS | Readiness, 5s retry, 60s freshness, enqueue failure, demand, pause/wake, retained data and wrap | Explicitly does not cover the enclosing BleIntegration 45s episode/cooldown. |
| `transit_buffer_test.cpp` | PASS | PASS, unchanged | Fragmentation, idle boundary, reset, NUL/size rejection and recovery | Existing bounded-buffer checks retained. |

Firmware harness paths above are under `arduino/sketch_cta_ble_demo/tests/`.

## New small harnesses

| Test | Previous State | Current State | Behavior Protected | Notes |
|---|---|---|---|---|
| `tests/protocol_contract_test.swift` | Not present | PASS | Six canonical serialization byte goldens, P1 header, truncation/pruning, agency metadata, display identity, distance/window boundaries | Same `.tp2` files are decoded by firmware; golden files are never auto-updated. |
| `protocol_contract_test.cpp` | Not present | PASS | Same fixtures; atomic rejection/retention, duplicate display identity, P1 count/size/CRC/reset/recovery and capacity | Own logic only; no BLE mocks. |
| `tests/delivery_diagnostics_test.swift` | Not present | PASS | Request/ACK parsing; session/boot/length/status matching; duplicate/cancel/eviction; diagnostics order/CRC; timeline sync/dedup/missing completion | No claim of ATT cancellation, disk-before-ACK or firmware purge coverage. |
| `tests/realtime_validation_test.swift` | Not present | PASS | Manifest invalid schema/colors/coordinates/references; realtime timestamp/reference checks; ordering, stale-generation rejection, retained snapshot on failure | Uses an existing realtime protocol with two controlled continuations, not a new production seam. |

Expected offline outcome: **17 automated passes, one compiled-only live harness, one manual renderer harness**. The runner prints actual results, stores `results.json` outside the checkout and exits nonzero for any automated failure. A production compiler warning about unnecessary `await` in MTAClient is retained; fixing it is outside this testing pass.

The app's developer BLETestRunner/BLETestView, reconnect experiment and disabled firmware BleWakeTest are interactive utilities rather than standalone host tests. Their real-device behavior remains manual. The Xcode scheme has no XCTest testables; no test target or platform mock framework was introduced.

All observed baseline failures above are attributable to stale test contracts/dependencies; none required a production fix. Source-level audit concerns remain open until separately reproduced/decided. No physical hardware, live feeds, full Xcode build or Arduino platform build was exercised by the offline test run.

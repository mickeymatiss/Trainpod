# Aggregate verification

Ten bounded production passes completed; F13 stopped for the requested policy decision. C1–C7 remain unstarted. Work is on `engineering/bounded-campaign` in the isolated campaign checkout. Original source checkout and main were not modified; nothing was pushed.

## Final results

- **24 standard host executables PASS:** 11 Swift and 13 C++.
- **One additional deterministic host characterization PASS:** nearby retry policy; deliberately separate from the standard runner.
- **One additional simulator controller harness PASS:** actual DeviceUIColor/DeviceTheme with narrow transport doubles (F05). Its old-source run failed the stale-confirmation assertion and the fixed-source run passed. This was performed at the F05 commit; later passes do not change those sources.
- **Normal Xcode Debug iOS Simulator build PASS** after the final production changes; no signing/project changes.
- **ESP32-C6 firmware target compile PASS** after the final changes; no upload/build-configuration changes.
- Public MTA smoke harness compiled but was **not run**. Legacy eta_render_test remains **manual**.
- **No physical hardware test was performed.** Manual obligations are listed below.

## Every standard harness

| Harness | Final status |
| --- | --- |
| platform_formatter_test | PASS |
| mta_arrivals_test | PASS |
| transit_manifest_test | PASS |
| nearby_arrival_identity_test | PASS |
| diagnostic_render_test | PASS |
| diagnostic_scope_test | PASS |
| cta_cache_test | PASS |
| ble_write_wait_test | PASS |
| protocol_contract_test | PASS |
| delivery_diagnostics_test | PASS |
| realtime_validation_test | PASS |
| mta_live_smoke | COMPILED (NOT RUN) |
| firmware_arrival_screen_test | PASS |
| firmware_button_navigation_test | PASS |
| firmware_display_direction_test | PASS |
| firmware_eta_fade_test | PASS |
| eta_render_test | MANUAL — legacy harness retained |
| firmware_mta_arrivals_contract_test | PASS |
| firmware_mta_station_test | PASS |
| firmware_platform_dip_test | PASS |
| firmware_platform_pages_test | PASS |
| firmware_protocol_contract_test | PASS |
| firmware_receiver_test | PASS |
| firmware_refresh_deadline_test | PASS |
| firmware_refresh_flow_test | PASS |
| firmware_transit_buffer_test | PASS |

## Reproduction and scope

From the campaign checkout:

```sh
python3 tests/run_tests.py --output /tmp/keytrain-host-tests
python3 tests/run_nearby_retry_policy_test.py --output /tmp/keytrain-policy-test
```

The standard runner compiles actual production logic, with its existing platform support. It does not test CoreBluetooth callbacks. The F13 runner checks there is exactly one production 60-second sleep expression, copies the view model outside the checkout, and replaces only that expression with a stepped test clock. Provider/environment doubles select success/error outcomes. This test protects agency branching, not networking or OS timer behavior. Two exploratory wall-clock runs failed an elapsed-time assumption and are not counted as passing tests.

Theme simulator instructions are in `tests/ios/README.md`. The harness is separate because UIKit requires an iOS simulator. The temporary simulator used for F05 was shut down and deleted; existing simulators were not altered.

Xcode command (external derived-data path omitted here for portability):

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project 'KeyTrain Connect.xcodeproj' -scheme 'KeyTrain Connect' \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/keytrain-derived-data build
```

ESP32 compile used Arduino IDE's installed arduino-cli, its existing config, core **3.3.11**, and FQBN **esp32:esp32:esp32c6** found in installed Arduino metadata. No option overrides. Final compile: **941626 bytes program storage**, **192688 bytes global memory**. External build/output paths used; CLI-created sketch build artifacts moved outside the checkout. This establishes compilation for the discovered target, not physical wiring or radio/display success.

Pre-existing Xcode deprecation/App Intents warnings remain. A preliminary F02 cache-symlink build failed during module loading; rerunning with a real independent cache passed without changing fixtures. Those failed experiments are retained in the evidence archive.

## Cross-platform invariants

Swift and C++ protocol harnesses passed the shared TP2/P1 fixtures, including checksum, malformed/incomplete input and near-capacity cases. Protocol fixtures are byte-identical to baseline `297bcc5`. Generated `platform.txt` and `mta.txt` are byte-identical to the original campaign baseline. Production formatter/TransitMessage, framing and parser code are unchanged. F11 changes only the rendered interpretation of compound direction labels, not serialized bytes.

The verification manifest records SHA-256 for each fixture and generated payload. Golden fixtures were not updated to accommodate any change.

## Rollback verification

All ten production commits retain their own conceptual boundaries. Raw reverse application was checked in a throwaway clone: shared reports conflict for older commits; the dense runner registry also conflicts where multiple tests were registered. F01 has two nearby BLE guard overlaps with later passes. No claim of conflict-free raw `git revert` is made.

Prepared reverse patches remove one pass's production changes and dedicated tests while retaining later unrelated work. They omit cumulative report rewinds. F01 keeps F02's active-peer check and F03's disconnect ownership guard. F09 also removes the F09-dependent cross-session assertion from the later F10 test; its render-certainty checks remain. The standard host suite was run after each individual reverse patch at the combined production head, with no failures. F13 subsequently adds only a separate test and report and does not overlap these patches.

| Removed finding | Remaining standard harnesses PASS |
| --- | --- |
| F01 | 23 |
| F02 | 24 |
| F03 | 24 |
| F04 | 23 |
| F05 | 24 |
| F09 | 23 |
| F10 | 23 |
| F12 | 23 |
| F11 | 23 |
| F14 | 23 |

These rollback checks prove patch applicability and remaining host tests, not native builds or hardware behavior for each reverted combination. Reverting a reliability fix deliberately restores its previous defect. Before applying a patch to a future changed checkout, use `git apply --check`, review the diff, then repeat native/manual checks relevant to that pass. Do not apply the reverse patch and also revert the same commit.

## Combined manual session — not yet performed

| Scenario | Findings / commits | What to check |
| --- | --- | --- |
| Cold boot, normal and repeated refresh; background request | F01 `d022b55`, F02 `faa100f` | Normal writes/ACKs; no unnecessary retirement; sender remains available. |
| Cancel an actually outstanding response write using debugger timing; allow reconnect and next refresh | F01 `d022b55` | Exactly one resolution, connection retirement, no reuse before disconnect, late old completion cannot satisfy new write, next send succeeds. |
| Cancel before submission, after completion, and during no-response readiness | F01 `d022b55` | No response-retirement unless an unresolved response write existed; no-response wait releases and future send works. |
| Disconnect/reconnect, Bluetooth interruption, subscription failure/disable and legitimate resume | F01 `d022b55`, F02 `faa100f` | Recovery; retry does not use stale peripheral; duplicate subscription success does not duplicate startup. |
| A→B switch with delayed A callbacks; theme X on A/B/A | F03 `5993694`, F05 `708640f` | B clock/session untouched by A; B receives unconfirmed X; same-device dedup and manual Push preserved; persistence smoke. Two physical devices if available. |
| Ordinary standby/wake | F12 `fe53a58` | Optional wake/refresh smoke. Long dormant interval itself is deterministic arithmetic coverage, not a claim of weeks on hardware. |
| Page/navigation transitions and available compound direction in standard/compact display | F11 `27fc013` | Correct N./S. East/West text and fit, unchanged navigation. |
| Diagnostic export, ideally after A/B use | F09 `e21552d`, F10 `203159c` | Sessions remain distinct; absent DISPLAY_UPDATED is unknown rather than proven render failure. Optional export integration check. |
| Nearby list with equal ETAs | F14 `a7dc7a9` | Optional visual confirmation of two rows and unchanged order/content. |

Detailed forced BLE boundary scenarios are in PassResults. Host builds cannot replace them. CTA cache recovery and diagnostic classification are deterministic; no new radio-specific checks are imposed for those passes.

## Human-readable assessment

The changes preserve the working architecture. The important fixes release abandoned transport waits, prevent stale device state from contaminating later work, keep a disposable cache from defeating valid transit data, and make diagnostics more honest. Firmware changes are limited to two deadline assignments and pure direction text.

The largest remaining uncertainty is still real CoreBluetooth timing: the host tests prove KeyTrain's state ownership, while the hardware session must verify actual disconnect/reconnect behavior. The nearby retry discrepancy needs a product choice, not a guess. Stopping here leaves useful, tested improvements and a clean policy boundary; it does not imply the rest of the code needs rewriting.

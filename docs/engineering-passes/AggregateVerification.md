# Aggregate verification — through F05

This is an interim aggregate, not completion of the whole campaign. F01, F02 and F03 are PASS — MANUAL VERIFICATION REQUIRED. Later passes remain outstanding.

F02 additionally passed the normal Xcode simulator build and all 18 host executables on a clean cache. Its initial symlinked-cache run failed during module loading; the successful run used an independent cache, with unchanged sources/fixtures. F02 callback transitions remain manual obligations.

F03 passed all 18 host executables and the normal Xcode simulator build. Its actual A/B callback sequence remains manual; source tracing and pure ownership tests are not CoreBluetooth integration coverage.

Latest aggregate after F04: **19 executable harnesses PASS** (eight Swift, eleven C++), plus the Xcode simulator build. CTA cache recovery was characterized with a failing pre-fix test and passing post-fix fixtures.

F05: all 19 host executables and the normal Xcode simulator build PASS. A separate UIKit app harness compiled the real theme controller/model: the pre-fix source failed the stale-confirmation assertion and the fixed source passed all A/B/A, deduplication and manual-Push cases. This is one additional simulator harness, not part of the 19 host count or hardware proof. Temporary simulator removed after verification.

## Host suite

Before F01: 17 executable harnesses PASS. After F01: **18 PASS**, **one compiled-only**, **one manual**. Seven Swift and eleven firmware C++ harnesses executed. The added wait test compiles production state/continuation code directly, not CoreBluetooth mocks.

| Harness | Status |
| --- | --- |
| platform_formatter_test | PASS |
| mta_arrivals_test | PASS |
| transit_manifest_test | PASS |
| cta_cache_test | PASS |
| ble_write_wait_test | PASS |
| protocol_contract_test | PASS |
| delivery_diagnostics_test | PASS |
| realtime_validation_test | PASS |
| mta_live_smoke | COMPILED (NOT RUN) |
| firmware_arrival_screen_test | PASS |
| firmware_button_navigation_test | PASS |
| firmware_eta_fade_test | PASS |
| eta_render_test | MANUAL — legacy harness retained |
| firmware_mta_arrivals_contract_test | PASS |
| firmware_mta_station_test | PASS |
| firmware_platform_dip_test | PASS |
| firmware_platform_pages_test | PASS |
| firmware_protocol_contract_test | PASS |
| firmware_receiver_test | PASS |
| firmware_refresh_flow_test | PASS |
| firmware_transit_buffer_test | PASS |

Commands used `python3 tests/run_tests.py --output <external-directory>`; all artifacts stayed outside the checkout. The new test was also compiled/run directly before integration. The original raw-continuation experiment is retained as historical evidence and is not part of the passing production-harness count.

## iOS target build

**BUILD SUCCEEDED**, normal Debug generic iOS Simulator build after F01, using the installed Xcode via command-scoped `DEVELOPER_DIR`. Project, signing and dependency settings were unchanged. Existing `bluetoothCentrals` deprecation and App Intents metadata warnings remain unrelated. No simulator UI test or physical BLE success is claimed.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project 'KeyTrain Connect.xcodeproj' -scheme 'KeyTrain Connect' -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath <external-derived-data> build
```

## Firmware target

The Arduino IDE bundled CLI, ESP32 core 3.3.11 and RISC-V compiler are installed. The exact current FQBN and board-option set were not established from the checked-in configuration or narrowly inspected IDE recent-sketch metadata. **Target build not run**: no target/options were guessed or modified. Eleven firmware host harnesses passed; that is not evidence of a successful ESP32 build or hardware session.

## Cross-platform contracts

The Swift and C++ protocol contract harnesses both passed against the existing shared TP2 fixtures and P1 header. Formatter-generated platform and MTA payloads were also consumed successfully by the firmware harnesses. Production serialization, checksum, capacity, framing and parser code are unchanged. This establishes baseline golden compatibility, not any unimplemented pass.

Protocol fixture SHA-256 values at the verified baseline (unchanged after F01):

| File | SHA-256 |
| --- | --- |
| README.md | 7877a239c3cecf038ac8c17af6885bcb9f8b47df5d3b4b9a8ef2eedd60f64d72 |
| agencies.tp2 | 6a1dfaab7fc1cf82ca120628f0fe53c4da2345bf5dc8b13dda555bcf12002d71 |
| bad_checksum.tp2 | f0c53cd6a25c19b19286fb95166ca740c360fe8a773717f2d9531e90f885b018 |
| bad_record.tp2 | 72a18cbe4bee6b6704b2ef2130789b3e40bd91f3e195b1822a509582613df5e0 |
| cta.header | 6938ba3d99fedf55785a3aab7a0c8e77a8f3a27e729f1f5e281247dc90db31a2 |
| cta.tp2 | 60cdb48ad6cac5c081393b3e77fffca6c5d7e72b50726ff9cbb82d7b0a5e0978 |
| identity.tp2 | 9cacb41cd242621938baf428fd06b2444914975b4137f48171e6b31a9ca50256 |
| incomplete.tp2 | 3cdd160cfbcc91773af356fc9eb8b46b5468cfe6637424a652d5bf46ab16d63c |
| index.tsv | f7bd4e514b609b0c8f99527d36697328959b4c884bbccd447b2d0ff245964e43 |
| inputs.json | 706c559ba1aa3f7662bb58ce6f16f1ee7b770ebbf402862a6c574900c0047974 |
| long_names.tp2 | f21c4bf49bc4e2d3dc5bd3395beb815d99857638472662c7f77c4ffda2d31b0a |
| mta_empty.tp2 | 306bd2cdc30cc99e99e3e762f46b84d2997fa25d74d5e5934aa2bd0dfce3d1bd |
| near_limit.tp2 | 47caf4f96a6eb9b54e0c6ce2513f3a808957f4c4bdbac51f6779247fb0d44d0a |
| unavailable.tp2 | 2a0a27ce60a93f04b71b17fa6802a3e170591d379c3b202ae41488f86a73a6e6 |

## Rollback and remaining verification

F01 changes two BLE implementation files, adds its focused host test, registers that test, and updates reports. It leaves wire serialization, MessageBridge, retry/request machinery and firmware unchanged. Its implementation commit is independently revertible. F01-M1 through F05-M4 in PassResults.md remain physical/manual obligations. The final aggregate run and combined manual map will be produced after subsequent passes.

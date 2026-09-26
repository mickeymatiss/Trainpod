# Aggregate verification — interim baseline, not campaign completion

The campaign is paused before the F01 production change. No subsequent pass has begun. These results establish the preserved baseline; they do not verify the requested fixes.

## Complete host suite

Command: `python3 tests/run_tests.py --output <external-artifact-directory>`.

Result: **17 PASS**, **1 compiled-only**, **1 manual**. The executable total consists of six Swift harnesses and eleven C++ harnesses. Live network execution was not requested or performed. The legacy renderer harness was not run.

| Harness | Status |
| --- | --- |
| platform_formatter_test | PASS |
| mta_arrivals_test | PASS |
| transit_manifest_test | PASS |
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

The complete suite ran before any campaign production changes. No production or existing test changes followed, so no redundant final rerun was performed. A true final aggregate run remains required after the campaign's successful passes.

## F01 runtime experiment

`docs/engineering-passes/F01-continuation-probe.swift` is a standalone Swift language experiment, not a CoreBluetooth mock or a production regression harness. It is deliberately not registered in the existing test runner and is not counted among the 17 passing tests.

```sh
swiftc -parse-as-library -module-cache-path /tmp/keytrain-f01-cache docs/engineering-passes/F01-continuation-probe.swift -o /tmp/keytrain-f01-probe
/tmp/keytrain-f01-probe
```

Observed: task cancellation leaves the checked continuation suspended and the enclosing defer unexecuted; explicitly resuming it with `CancellationError` releases the task and executes cleanup. The six requested end-to-end lifecycle cases are **not yet verified**.

## Xcode

**BUILD SUCCEEDED**, Debug, generic iOS Simulator, both simulator architectures selected by the existing project. Used the installed Xcode via a command-scoped `DEVELOPER_DIR`; did not change `xcode-select`, project configuration, signing settings, or dependencies. The initial sandboxed project-list command could not access simulator services; the authorized build with normal service/cache access succeeded.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project 'KeyTrain Connect.xcodeproj' -scheme 'KeyTrain Connect' -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath <external-derived-data> build
```

This was a compile/build, not a simulator UI execution, phone run, or hardware BLE test.

## Firmware target

The Arduino IDE bundled CLI, ESP32 core 3.3.11 and RISC-V compiler are installed. The exact current FQBN and board-option set were not established from the checked-in configuration or narrowly inspected IDE recent-sketch metadata. **Target build not run**: no target/options were guessed or modified. Eleven firmware host harnesses passed; that is not evidence of a successful ESP32 build or hardware session.

## Cross-platform contracts

The Swift and C++ protocol contract harnesses both passed against the existing shared TP2 fixtures and P1 header. Formatter-generated platform and MTA payloads were also consumed successfully by the firmware harnesses. Production serialization, checksum, capacity, framing and parser code are unchanged. This establishes baseline golden compatibility, not any unimplemented pass.

Protocol fixture SHA-256 values at the verified baseline:

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

The F01 record/probe commit changes documentation and an isolated experiment only. It can be reverted without changing runtime behavior. The prerequisite characterization snapshot is a separate commit and should not be mistaken for a production fix.

No manual scenarios can be mapped to changed production code yet. After an approved F01 implementation, cancellation/recovery and subsequent-send smoke checks will be required. Later passes must add their own commit-specific checks. The combined final hardware session and final aggregate run remain outstanding.

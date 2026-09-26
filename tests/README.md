# Lightweight host characterization

From the repository root on macOS with Swift and clang++ available:

```sh
python3 tests/run_tests.py
```

The runner creates an external temporary directory, prints each result, stores compiler/runtime logs plus `results.json`, and exits nonzero for an automated failure. Set `--output /absolute/path/outside/the/checkout` to retain artifacts at a chosen location. Assertions remain enabled; no optimized `-O`/`-DNDEBUG` build is used. It does not write to the checkout, modify app preferences, contact transit services, or operate a phone/device by default.

The suite compiles production model/parser/formatter/validation sources directly. `support/HostSupport.swift` only supplies a no-op file logger and the provider's error cases to avoid loading UIKit-dependent code. It contains no replacement algorithms. Manifest HTTP checks use their existing URLProtocol stub; controlled manifest/realtime clients use existing protocols, with no production test seams added.

The existing public MTA network harness is compiled but not executed by default. If intentionally testing live availability, use `python3 tests/run_tests.py --live`; network/data failures are separate from deterministic host regressions. It uses a fixed public Times Square coordinate, not the user's location.

## Scope

- Existing formatter, MTA, manifest, receiver, buffer, navigation, pagination, refresh and animation checks are repaired for release 1 behavior.
- `protocol_contract_test.swift` and firmware `protocol_contract_test.cpp` share six accepted TP2 byte goldens, four rejected/unavailable cases and a P1 header. Sources/expected behavior are documented in `fixtures/protocol/README.md`.
- `delivery_diagnostics_test.swift` protects wire parsing, ACK identity/session/length/status matching, duplicate/cancel/eviction behavior, diagnostic assembly rejection and pure timeline transforms. It does **not** establish filesystem persistence-before-purge or BLE timeout recovery.
- `realtime_validation_test.swift` protects manifest/reference validation, realtime timestamp/reference behavior and late response rejection using the existing service interface. Old realtime snapshots remain inspectable; the resolver does not enforce the serving layer's 180-second freshness gate.
- `eta_render_test.cpp` is explicitly **MANUAL**, not a passing host test. Its old API/Arduino/TFT stubs no longer represent the production canvas/task renderer. It is retained for historical intent; this pass does not add a fake ESP32/TFT environment. M8 carries its visual checks. Existing pure ETA and page-transition tests still run.

See [TEST_INVENTORY.md](TEST_INVENTORY.md), [MANUAL_SMOKE_TESTS.md](MANUAL_SMOKE_TESTS.md) and [CleanupSafety.csv](CleanupSafety.csv). Manual and live-network checks are not included in the automated pass count.

## Review discipline

On a fixture mismatch, inspect the production behavior and protocol intent; do not regenerate expectations merely to make a failing change pass. The contract test saves a mismatching `actual-*.tp2` only in the external run directory for inspection. Compare it to the checked-in bytes. Source changes require a separate decision.

`payload(from:)` reads its own clock and has no injected time argument. The serialization test places arrivals halfway through minute buckets and fails if an individual case takes ten seconds; it does not claim complete virtual-clock isolation. Window boundary tests call `upcomingTrains(at:)` with a fixed time. Exact wall-clock boundary integration remains outside this pass.

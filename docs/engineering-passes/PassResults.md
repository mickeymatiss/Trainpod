# KeyTrain bounded engineering campaign

## Baseline and rollback

Work is isolated on `engineering/bounded-campaign`. Original checkout and main remain untouched; nothing is pushed. Release 1 is `8fc1dad`. Prerequisite commit `297bcc5` preserves the previously uncommitted characterization tests; it is not an implementation pass. `007150c` records the initial F01 investigation and policy question. The user subsequently authorized narrowly retiring a connection when cancellation intersects an unresolved response write.

## Pass 1A — F01

**PASS — MANUAL VERIFICATION REQUIRED**

- **Finding:** cancelled transport waits could leave `BluetoothService.writeInProgress` and `MessageBridge.sending` occupied indefinitely. Releasing an unresolved response write without retiring its connection would allow an old ATT callback to satisfy a later write.
- **Files changed:** `Trainpod/Platform/BLE/BluetoothService.swift`, new `Trainpod/Platform/BLE/BLEWriteWait.swift`, new `tests/ble_write_wait_test.swift`, the harness registration in `tests/run_tests.py`, and these pass/verification reports.
- **Characterization:** the preserved runtime probe first confirmed raw continuation cancellation does not execute enclosing cleanup. The new test compiles the production wait and retirement gate directly; plain object identities stand in for callback ownership, without a fake CoreBluetooth framework. Tests cover normal completion, explicit failure, disconnect, supersession, duplicate completion, cancellation before submission, cancellation while waiting, resolution-before-retirement ordering, completion winning a cancellation race, unrelated disconnect, late old callback ownership after the disconnect barrier, successful subsequent wait, and no-response readiness cancellation/reuse.
- **Production change:** each suspension has a separate MainActor-owned continuation. Cancellation completes only that wait, exactly once. A cancelled outstanding response write clears its pending slot and retires its connection in the same actor turn before released sender cleanup can permit another write. The retired peer is blocked in send/readiness/discovery paths until its disconnect callback. Existing reconnect and GATT discovery remain authoritative. Readiness-only cancellation clears its wait without retiring the connection. Already completed or never-submitted writes do not trigger retirement.
- **Targeted tests:** `ble_write_wait_test` PASS. Existing runtime probe previously PASS; not counted as production coverage.
- **Broader tests before:** 17/17 host executables PASS. **After:** 18/18 PASS (seven Swift, eleven C++); public MTA live smoke compiled only, legacy ETA renderer manual. Debug Xcode generic iOS Simulator build PASS, with unchanged project/signing settings. Shared TP2/P1 goldens PASS on both platforms.
- **Diff review:** no MessageBridge, request coordinator, firmware, payload, framing, MTU/chunk, resend or retry policy changes. Existing peripheral-ownership checks remain; response completion additionally uses the wait's original peripheral/characteristic identities. Registration of the new harness is the only runner change.
- **Manual verification:** required; see scenario F01-M1 through F01-M4 below.
- **Remaining limitation:** host tests exercise KeyTrain-owned continuation/ownership state and the disconnect gate, not OS callback delivery, actual radio disconnection, or physical reconnection. Recovery uses the existing reconnect path and does not guarantee service if the peripheral remains unavailable. No new retry or automatic resend is introduced.
- **Commit message:** `reliability(ble): resolve cancelled pending writes [F01]`. Exact identifier is recorded in the delivered report and final campaign table after commit.
- **Rollback:** revert this one implementation commit to restore prior behavior and remove its harness registration; the earlier characterization baseline remains independently intact.

### Why the disconnect barrier is sufficient within the documented contract

Response delegate handling remains synchronous on the main queue. Before disconnect, the retired gate and cleared pending slot reject the abandoned completion. After disconnect, CoreBluetooth invalidates services and characteristics; the next wait must match its newly discovered characteristic object. Apple documents no further peripheral delegate calls after the disconnect callback. See [Apple disconnect contract](https://developer.apple.com/documentation/corebluetooth/cbcentralmanagerdelegate/centralmanager(_:didDisconnectPeripheral:error:)) and [nonblocking cancellation](https://developer.apple.com/documentation/corebluetooth/cbcentralmanager/cancelperipheralconnection(_:)). This is an OS contract plus local ownership guards, not an invented application write ID in the callback.

### Manual smoke scenarios for the actual change

- **F01-M1 — Normal/repeated refresh:** cold boot, connect, complete several refreshes, and issue a background request. Check normal response writes/ACKs; no cancellation-retirement log should appear. Covers unchanged normal writes and sender release.
- **F01-M2 — Cancel an outstanding response write:** use a debug breakpoint after a response continuation is installed, cancel the owning task before delivering its completion, then continue. Confirm one cancellation resolution, one retirement request, and no further logical writes before disconnect. Let the existing reconnect/request path run; confirm a subsequent refresh succeeds. Check late old completion cannot mark the new operation complete. Host state tests cover the sequence; real callback timing still needs physical observation.
- **F01-M3 — Ordinary interruption:** disconnect/reconnect and Bluetooth off/on during a send; verify existing reconnection and a later request. Do not interpret an unavailable peripheral as automatic retry success.
- **F01-M4 — Non-response cancellation boundaries:** cancel before transport submission, after successful response completion, and while waiting for no-response capacity. The first two must not retire; readiness cancellation must release without a retirement request. A later send must remain possible. Use a debugger to create the readiness boundary if normal traffic never saturates it.

No hardware checks have been run. These scenarios validate F01 only and will be consolidated with later successful passes.

## Pass 1B — F02

**PASS — MANUAL VERIFICATION REQUIRED**

- **Files changed:** `BluetoothService.swift` and the pass/aggregate reports.
- **Behavioral problem:** notification failure or disable left `dataPathStarted` true, making a later Connect/resume return without retrying startup.
- **Characterization used:** direct state-transition trace through `resumeDataPath`, identity verification, configuration, notification callbacks and disconnect. Failure now yields `dataPathStarted = false` plus no writable handle; retry re-enters the existing identity/discovery flow. Success retains the started latch; duplicate success returns while already connected. Disconnect keeps its original reset. Retry now rejects a non-owned or non-connected peripheral and a non-powered-on central.
- **Production change:** six added guard/reset lines, no discovery/reconnect or identity algorithm change. Clearing the failed handle also prevents a delayed success for that failed attempt from restoring readiness before a legitimate resume.
- **Targeted verification:** source transition review and actual iOS target build PASS. No host regression test was added: testing this delegate-specific glue independently would require a fake CoreBluetooth layer or extracting trivial booleans solely to test them. The existing host tests do not prove notification recovery. The five requested scenarios are explicit manual obligations below.
- **Broader tests:** pre-change suite was F01's green 18; post-change clean-cache run 18/18 PASS, one compiled-only, one manual. Debug Xcode simulator build PASS. An initial cache-symlink reuse attempt caused Swift duplicate-module/compiler failures and downstream generated-payload failures; preserved separately, then rerun successfully with an independent cache. No fixtures or expectations were changed to resolve that tool-cache failure.
- **Manual required:** F02-M1 normal subscription emits readiness once; F02-M2 inject failed/disabled subscription then use existing Connect/resume and confirm recovery; F02-M3 duplicate success does not re-announce readiness; F02-M4 disconnect resets startup; F02-M5 attempt a stale-peer resume across A-to-B selection and confirm no discovery starts on A. Combine with F01 normal/reconnect smoke where possible.
- **Known limitation:** no automatic retry trigger was added. Recovery waits for an existing legitimate resume/reconnect action. OS subscription/identity interaction remains hardware verified, not host verified.
- **Commit message:** `reliability(ble): allow notification startup retry [F02]`.
- **Rollback:** independently revert the local guard/reset changes; no new dependency on the F01 helper was introduced.

## Campaign progress

F01 and F02 have been implemented. Subsequent passes are not yet evaluated; they are not classified as blocked or safe. The campaign continues in the requested order, with independent commits.

| Pass | Finding | Commit | Targeted Tests | Full Suite | Manual Test Needed | Result | Rollback Safe |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1A | F01 | `d022b55` | BLE wait/retirement/ownership: PASS | 18 host PASS; Xcode PASS | F01-M1–M4 | PASS — MANUAL VERIFICATION REQUIRED | Yes, independent commit |

| 1B | F02 | See delivered commit ID | State trace + Xcode PASS; callbacks manual | 18 host PASS | F02-M1–M5 | PASS — MANUAL VERIFICATION REQUIRED | Yes, local guard/reset changes |

## Deliberately unchanged

F03, F04, F05, F09, F10, F12, F11, F14, F13 and C1–C7 await their separate passes. F06, F08, F15–F19+, security/ownership, provisioning, renderer, power architecture, provider policy, protocol and broad naming changes remain explicitly out of scope. F07 shared location waiters was not in the authorized pass list and remains unchanged.

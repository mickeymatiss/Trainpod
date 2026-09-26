# KeyTrain bounded engineering campaign — paused at F01

This is an interim report, not a completed campaign. No production code or existing test has been changed. The next pass has not begun.

## Baseline and rollback boundary

The working prototype is release 1, `8fc1dad`. The original checkout contained uncommitted characterization work. An isolated local checkout on `engineering/bounded-campaign` preserves that work in prerequisite commit `297bcc5` (`test: preserve pre-campaign characterization baseline`). This is a snapshot of pre-existing work, not an implementation pass. The original checkout and main remain untouched; nothing has been pushed.

## Pass 1A — F01

**Result: BLOCKED** — awaiting a recovery-policy clarification before production work.

- **Files changed:** this report, `AggregateVerification.md`, and `F01-continuation-probe.swift` under `docs/engineering-passes/`. No production changes.
- **Behavioral problem:** `BluetoothService.writeChunk` stores checked continuations for ATT response and no-response readiness. Neither wait registers a cancellation handler. The refresh deadline cancels `sendTask`; this does not itself resume either continuation. `BluetoothService.write` retains `writeInProgress`, and `MessageBridge.send` retains `sending`, until their awaits exit and their `defer`s run.
- **Characterization added/used:** a small, deterministic Swift runtime probe confirms that cancellation alone leaves a checked continuation suspended and that explicit failure releases it and its enclosing `defer`. It uses no CoreBluetooth mocks. It is an experiment on the underlying Swift primitive, **not** production regression coverage or a six-case BLE lifecycle test. Existing diagnostic tests establish ACK matching, not transport continuation cancellation.
- **Production change:** none. A naive cancellation handler clearing the continuation was deliberately not installed.
- **Targeted tests:** compiled the probe with `swiftc -parse-as-library`; both observations passed. The first compilation omitted `-parse-as-library` and failed; the corrected invocation compiled and ran successfully.
- **Broader tests:** all 17 executable baseline host harnesses passed. MTA live smoke compiled only; legacy ETA renderer remained manual. Normal Debug Xcode simulator build succeeded without modifying signing or project configuration.
- **Manual verification required:** any eventual F01 fix must exercise cancellation during both write modes, late completion, reconnect recovery if used, and a subsequent send on real hardware. Nothing here establishes hardware success.
- **Known remaining limitation:** F01 remains present. No exactly-once completion or forward-progress fix has been claimed.
- **Commit message:** `docs(ble): record cancellation recovery decision boundary [F01]`. The exact identifier is included in the delivered report after committing.

### Why a policy decision is needed

`didWriteValueFor` receives a peripheral and characteristic, but no application write identifier. Its current guard checks the active peripheral, pending characteristic and presence of a pending continuation.

Consider this trace:

1. Write W1 is submitted on peripheral P / characteristic C.
2. W1 is cancelled; a naive handler clears and resumes its continuation.
3. W2 starts on the same P / C.
4. A delayed W1 callback arrives. It satisfies the current guard for W2.

An application operation token can protect a delayed **cancellation handler**, but cannot be recovered from this ATT callback. Keeping a tombstone and waiting for W1's callback can instead recreate the permanent stall when that callback never arrives. No-response readiness is different: it announces capacity rather than completion of a particular write, but that distinction does not solve response-write ownership.

A practical candidate is to retire the connection when an outstanding response write is cancelled, release the logical sender, and recover through the existing reconnect path with careful callback/connection ownership guards. That adds a cancellation-triggered connection transition. The task explicitly says not to change retry semantics or BLE availability architecture, so this policy has been raised for clarification rather than silently introduced. Connection retirement alone is not yet a verified fix; its stale-callback ordering and resumed-send behavior still need characterization and hardware verification.

**Pending question:** allow connection retirement specifically for a cancelled outstanding response write, using the existing reconnect path, or keep F01 blocked? No answer has been assumed.

### Implementation evidence

- `Trainpod/Platform/BLE/BluetoothService.swift`: continuation fields around 106–109; `write` / `writeChunk` / `resumePendingWrite` around 447–519; response/readiness delegates around 1076–1115.
- `Trainpod/Products/Transit/BLE/RefreshRequestHandler.swift`: background expiration and 25-second deadline cancel `sendTask` around 135–157.
- `Trainpod/Platform/Transport/MessageBridge.swift`: `sending = true` and `defer { sending = false }` around 124–125, followed by awaited writes.
- `arduino/sketch_cta_ble_demo/src/platform/ble/BleSession.cpp`: `abortSession` / `endSession` return when provisioning keeps BLE available, so firmware timeout is not a reliable disconnect escape hatch.

## Remaining passes

The user's sequential gate says not to begin the next pass with unclear behavior. No subsequent implementation pass has begun while F01's recovery policy is unresolved. These are **not** findings that have individually been judged unfixable.

| Pass | Finding | Commit | Targeted Tests | Full Suite | Manual Test Needed | Result | Rollback Safe |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1A | F01 | Documentation/probe only; see delivered commit ID | Runtime cancellation probe, not production lifecycle coverage | Baseline 17 PASS; Xcode build PASS | Required for eventual fix | BLOCKED | Yes: no runtime changes |
| 1B | F02 | None | Not begun | Baseline only | Subscription/reconnect | BLOCKED | No changes |
| 1C | F03 | None | Not begun | Baseline only | Device-switch callbacks | BLOCKED | No changes |
| 2 | F04 | None | Not begun | Baseline only | To determine during pass | BLOCKED | No changes |
| 3A | F05 | None | Not begun | Baseline only | Two-device themes | BLOCKED | No changes |
| 3B | F09 | None | Not begun | Baseline only | Export smoke if changed | BLOCKED | No changes |
| 4 | F10 | None | Not begun | Baseline only | Export wording/evidence if changed | BLOCKED | No changes |
| 5 | F12 | None | Not begun | Baseline only | Depends on eventual diff | BLOCKED | No changes |
| 6 | F11 | None | Not begun | Baseline only | Visual label if available | BLOCKED | No changes |
| 7A | F14 | None | Not begun | Baseline only | Simulator UI if changed | BLOCKED | No changes |
| 7B | F13 | None | Not begun | Baseline only | Retry policy unresolved by this campaign | BLOCKED | No changes |
| 8A | C1 | None | Not begun | Baseline only | Not determined | BLOCKED | No changes |
| 8B | C2 | None | Not begun | Baseline only | Not determined | BLOCKED | No changes |
| 8C | C3 | None | Not begun | Baseline only | Not determined | BLOCKED | No changes |
| 8D | C4 | None | Not begun | Baseline only | Not determined | BLOCKED | No changes |
| 8E | C5 | None | Not begun | Baseline only | Not determined | BLOCKED | No changes |
| 8F | C6 | None | Not begun | Baseline only | Not determined | BLOCKED | No changes |
| 8G | C7 | None | Not begun | Baseline only | Not determined | BLOCKED | No changes |

## Deliberately unchanged

F01 is unchanged pending the above decision. All other requested passes remain unstarted under the sequential/reliability gates. F06, F08, F15–F19+ and the user's excluded ownership/security, provisioning, renderer, power, provider-policy, protocol and naming changes remain out of scope. F07 (shared location waiters) was identified by the review but is not in the authorized implementation list and remains unchanged.

There is no touched-production manual smoke list yet: no production behavior has changed. An eventual F01 implementation will require its own mapped hardware checks and commit before any later pass begins.

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

## Pass 1C — F03

**PASS — MANUAL VERIFICATION REQUIRED**

- **Files changed:** `BluetoothService.swift` and pass/aggregate reports.
- **Behavioral problem:** a late A connect/disconnect callback could reset B's clock-sync flags/task, diagnostic session, or connection-pending bookkeeping before ownership was checked.
- **Characterization used:** bounded source event-sequence trace: select A → replace with B → A connect callback takes the rejection branch before clock/session/pending changes; A disconnect returns before session logging/clock mutation; B callbacks retain the original bookkeeping. The reconnect experiment first validates its own retained object through `handleConnected`, then follows the existing connected-state action. This trace is static evidence, not simulated OS callback execution.
- **Production change:** move only the identified bookkeeping behind existing ownership validation. Connect's adjacent MainActor blocks become one synchronous callback block so validation precedes those effects. No delegate framework or new ownership type. The F01 retirement gate still observes an old peer's disconnect before the active-peer guard, because clearing that peer's retirement marker is intentional. The raw disconnect timestamp diagnostic remains a global lifecycle observation, with no active-session/clock mutation.
- **Targeted verification:** reviewed the A/B event trace and diff; actual iOS target build PASS. Existing pure wait ownership test PASS. No CoreBluetooth mock was introduced; that wait test does not prove these delegate methods execute correctly on a device.
- **Broader tests:** pre-change F02 suite 18 PASS; post-change all 18 PASS, one compiled-only and one manual. Xcode Debug simulator build PASS.
- **Manual required:** F03-M1, select A then B and deliver/observe a late A connect or disconnect; B's diagnostic session, clock sync, pending connection and transport readiness must remain intact. Verify normal B reconnect and the opt-in reconnect experiment still work. Combine with two-device theme checks later.
- **Known limitation:** delayed real CoreBluetooth A/B callbacks and the reconnect experiment have not been physically exercised. The change preserves the existing identifier-based runtime guard; it does not redesign connection-generation identity.
- **Commit message:** `reliability(ble): guard stale peripheral bookkeeping [F03]`.
- **Rollback:** one local callback-ordering change, independently revertible; unrelated delegates are untouched.

## Pass 2 — F04

**PASS**

- **Files changed:** `CTAStationRepository.swift`, new `tests/cta_cache_test.swift`, one harness registration in `tests/run_tests.py`, and pass/aggregate reports.
- **Behavioral problem:** JSON/read errors prevented a fresh metadata fetch; persistence errors discarded successfully fetched mandatory CTA direction metadata.
- **Characterization:** deterministic HTTP fixture through URLProtocol plus the existing FileManager injection, with real temporary cache files. The test first failed on corrupt JSON blocking network and simulated out-of-space save discarding good results. After the fix it passes valid cache, missing cache, corrupt cache, network success/save success, network success/save failure, valid cache while upstream is unavailable, missing required direction mapping, and corrupt cache plus network failure. No live requests or user cache files are touched.
- **Production change:** catch cache-read errors before the unchanged network path, and catch cache-save errors after a valid nonempty fetched result. Log those two cache failures. A defaulted URLSession parameter supplies the focused HTTP test seam; ordinary callers still use shared URLSession, the same URL, timeout and decoding/grouping.
- **Targeted tests:** `cta_cache_test` red before recovery changes, green afterward. Actual repository code, not a parallel cache-policy implementation.
- **Broader tests:** before 18 host PASS; after 19 host PASS, one compiled-only, one manual. Formatter, realtime validation and shared protocol fixtures PASS. Xcode Debug simulator build PASS.
- **Manual verification required:** none for deterministic local cache semantics; an ordinary CTA refresh can be included in the final BLE smoke session without being represented as missing unit coverage.
- **Known remaining limitation:** usable cache remains authoritative with no fetch/age change; thus “failed network + usable cache” is represented by an unavailable upstream that is never called. Syntactically valid but semantically incorrect/non-nil direction dictionaries can still poison serving; validating or refreshing such metadata would change existing correctness/freshness policy and is not included. If required metadata cannot be recovered from either source, the original serving failure remains appropriate.
- **Commit message:** `reliability(cta): tolerate recoverable cache failures [F04]`.
- **Rollback:** independently revert repository recovery/seam, its harness and registration. No fallback policy, provider, formatter or firmware changes.

## Pass 3A — F05

**PASS — MANUAL VERIFICATION REQUIRED**

- **Files changed:** `DeviceUIColor.swift` (one assignment plus comment); `tests/ios/ThemeTransportSupport.swift`, `tests/ios/theme_controller_test.swift`, `tests/ios/README.md`, `tests/run_theme_controller_test.py`; pass/aggregate reports.
- **Behavioral problem:** A's acknowledged palette remained available for live-edit deduplication on B, suppressing B's intended update.
- **Characterization:** actual controller and theme model compiled into a temporary UIKit app; two small doubles provide only transport-facing callbacks/readiness/sent commands. Pre-fix source deterministically failed at the retained-A-confirmation assertion; fixed source passed A confirms X, A→B, B edit/select X sends, B→A, A edit/select X sends, same-connection deduplication and explicit manual Push. Six field packets plus the commit packet remain unchanged. The first standalone executable approach never reached the test body and timed out; it is not counted as a test result. The final app harness checks a success marker so simctl's own zero exit cannot mask an assertion failure.
- **Production change:** clear `deviceTheme` in the existing non-connected state handler, before pending confirmation cleanup. Selected/local edited themes remain intact. Invalidation is conservative per connection, so even reconnecting to the same device requires a new confirmation before deduplication trusts it. No per-device store, protocol, ACK token, fingerprint or firmware persistence changes.
- **Targeted tests:** UIKit theme-controller harness red before / PASS after. Temporary simulator created only for this characterization and removed afterward; runner installs/uninstalls its app and does not change the production project.
- **Broader tests:** pre-change 19 host PASS; post-change all 19 host PASS, one compiled-only, one manual; normal Xcode Debug simulator build PASS. The additional simulator controller harness is separate from those 19 host tests.
- **Manual required:** F05-M1 theme change/persistence on one physical device; F05-M2 A→B→A switching with different palettes and live editing, if two devices are available. Combine with F03 callback ownership checks. Re-enabling live editing alone still does not send, as before; selecting/editing a different palette or manual Push does.
- **Known limitation:** connection-boundary events in the simulator stand in for physical device switching. Real delivery, ACK timing and firmware persistence are not proven by these controller tests.
- **Commit message:** `fix(theme): scope confirmed theme to device [F05]`.
- **Rollback:** one independent controller assignment and self-contained test harness; no dependency on earlier fixes.

## Pass 3B — F09

**PASS**

- **Files changed:** `PhoneDiagnosticLog.swift`, `DiagnosticInterleave.swift`, the diagnostic TaskLocal context in `PayloadDelivery.swift`, diagnostic-only context/retention calls in `RefreshRequestHandler.swift`, new `tests/diagnostic_scope_test.swift`, its runner registration and reports.
- **Behavioral problem:** identical boot/request text from different sessions shared a retention bucket and report group, allowing unrelated stages to fabricate a successful transaction.
- **Characterization:** interleaved sessions A/B with transaction `1-1` first failed the two-group assertion on pre-fix code; fixed output has two incomplete traces rather than one invented success. Same-session legacy records still form one successful trace. Missing sessions do not join or pair spans. Six identical IDs across six sessions retain the newest five scoped transactions after the ordinary ring is evicted. A captured TaskLocal session stays old while the logger's current session changes to new.
- **Production change:** key retained/report transactions by existing diagnostic session plus unchanged wire ID; keep unknown-session events explicitly separate. Extend the existing diagnostic TaskLocal context with the captured request session so late logging does not silently adopt the next device's session. This changes observability only: live ACK matching, request generations, transaction state, payload and firmware are untouched.
- **Targeted tests:** `diagnostic_scope_test` red before / PASS after; `delivery_diagnostics_test` PASS. Example formatted report inspected: separate `session=a` and `session=b` traces, neither falsely successful. Raw input is not rewritten.
- **Broader tests:** before 19 host PASS; after 20 host PASS, one compiled-only, one manual; Xcode Debug simulator build PASS. The separate theme simulator harness remains a previously passing check.
- **Manual required:** none to establish deterministic grouping/retention; optional F09-M1 capture/export after two-device use during the final smoke session and confirm separate session labels.
- **Known limitation:** sessions are the existing per-connection random identifiers, not new globally unique physical IDs. Separate connections to the same physical device remain separate traces; historical logs without session evidence cannot be safely reconstructed as one transaction. Their missing evidence is labeled, not guessed. This pass does not invent new metadata, secrets or hardware identifiers.
- **Commit message:** `fix(diagnostics): scope transaction identity [F09]`.
- **Rollback:** one observability-only commit; no dependent live BLE behavior changes.

## Pass 4 — F10

**PASS**

- **Files changed:** `DiagnosticInterleave.swift`, new `tests/diagnostic_render_test.swift`, its runner registration and reports.
- **Behavioral problem:** applied + acknowledged + absent retained display completion was labeled render failure after 1.5 seconds, although supersession/pending render/lost logs can produce the same evidence.
- **Characterization:** pre-fix test failed for the falsely certain outcome. Fixed tests cover applied+display completed, applied+ACK without display, truncated logs, overlapping transactions, identical transaction IDs in different F09 session scopes, and explicit retained parse failure. A fixture annotates the real serial-only `RENDER_SUPERSEDED generation=…` format; because the structured export has no transaction/generation join, that extra annotation must not manufacture a proven superseded transaction.
- **Production change:** report `APPLIED / ACKNOWLEDGED — DISPLAY COMPLETION UNKNOWN` and explain which causes the retained evidence cannot distinguish. Confirmed display success and explicit failure events retain their classifications. No firmware/rendering/logging schema change or invented renderer event.
- **Targeted tests:** new render-evidence test red before / PASS after; all diagnostic reconstruction/scope tests PASS. Seven example formatted reports reviewed: clear success where supported, unknown for missing display evidence, separate overlapping/session traces, explicit parse failure retained.
- **Broader tests:** before 20 host PASS; after 21 host PASS, one compiled-only, one manual. Xcode Debug simulator build PASS. Protocol/formatter goldens unchanged.
- **Manual required:** none for this deterministic report wording; optional diagnostic export in the final device session can confirm the observed presentation.
- **Known limitation:** current structured firmware exports do not identify render supersession/failure by transaction. Serial evidence can help a human investigation, but this formatter cannot prove a superseded outcome from it. Other pre-existing outcome categories are outside this bounded render-certainty fix.
- **Commit message:** `fix(diagnostics): avoid false render failure classification [F10]`.
- **Rollback:** local classification/wording and its test only. No live device behavior changes.

## Pass 5 — F12

**PASS**

- **Files changed:** `RefreshFlow.h`, `BleIntegration.cpp`, new `tests/refresh_deadline_test.cpp`, and reports. Host C++ discovery automatically includes the new harness.
- **Behavioral problem:** an expired update deadline older than half the millis range appears future under signed subtraction. The same wake path reset the BLE-session deadline to zero, which also appears future at long uptime and could keep a correctly rearmed episode from starting BLE.
- **Characterization:** a pre-change arithmetic probe reproduced both comparisons rejecting a >half-range wake. The new harness exercises the production, narrowly named wake-rearm helper, ordinary deadlines, rollover, short standby, both sides of half-range, wake admission, subsequent five-second retry and sixty-second freshness. It preserves any genuine remaining cooldown instead of bypassing it on a short wake.
- **Production change:** on the existing paused→active transition only, retain a deadline at most five seconds ahead; otherwise rearm it at now. The BLE-session immediate-wake deadline is now millis rather than zero. No power side effects, mutex ownership, display state, retry interval, freshness threshold or 45-second episode limit changed. This is local deadline repair, not a timer framework.
- **Targeted tests:** old-expression probe confirms the failure; `firmware_refresh_deadline_test` and `firmware_refresh_flow_test` PASS.
- **Broader tests:** before 21 host PASS; after 22 host PASS (ten Swift, twelve C++), one compiled-only, one manual. Real firmware compile PASS with installed ESP32 core 3.3.11, FQBN `esp32:esp32:esp32c6` found in Arduino IDE metadata. No board option overrides, project/config edits or upload. Output: 941024 program bytes, 192688 global-variable bytes. CLI-generated sketch build artifacts were moved out of the checkout and not committed.
- **Manual required:** optional ordinary standby/wake smoke F12-M1; no GPIO/power behavior was changed. The long interval is verified arithmetically rather than by claiming weeks of physical observation.
- **Known limitation:** modulo millis cannot distinguish an exact full wrap from a new short cooldown; the rearm permits at most the normal five-second wait in that narrow alias case, rather than a semi-permanent stall. It does not redesign all firmware timer horizons. Installed board metadata establishes the FQBN, not undocumented physical wiring or hardware success.
- **Commit message:** `fix(firmware): rearm long-lived refresh deadline [F12]`.
- **Rollback:** two local wake deadline assignments and the pure helper/test; no iOS or protocol dependency.

## Pass 6 — F11

**PASS — MANUAL VERIFICATION REQUIRED**

- **Files changed:** `ArrivalScreen.cpp`, new pure `DisplayDirection.h`, new `tests/display_direction_test.cpp`, and reports.
- **Behavioral problem:** the East/West substring checks consumed compound directions before their North/South component could be preserved.
- **Characterization:** move the existing pure function into a header without changing behavior, then run the new fixture: `N.East` produced `East`, failing the expected output. The desired `N. East`, `N. West`, `S. East`, `S. West` convention is already established by the iOS formatter. Fixed fixtures cover all cardinals, all four compounds with/without period-space, full spellings, case/bound/hyphen variants, existing platform-prefix fallback and unrelated text. `Main East` and `Northampton East` preserve old behavior rather than becoming false compounds; bare `NE` retains its previous fallback.
- **Production change:** four compound-prefix checks precede unchanged cardinal substring/fallback behavior. Only the two renderer call sites use the extracted pure helper. No direction identity, grouping, station selection, parser or serialized-byte changes.
- **Targeted tests:** new display-direction harness red before / PASS after; existing arrival/page/render-policy host checks PASS.
- **Broader tests:** before 22 host PASS; after 23 host PASS (ten Swift, thirteen C++), one compiled-only, one manual. ESP32-C6 target compile PASS, no upload/config changes. Shared protocol fixtures unchanged.
- **Manual required:** F11-M1 visually check one available compound label in standard/compact display to confirm fit and glyph rendering; no physical device session was performed. Can be combined with page/navigation smoke.
- **Known limitation:** the host fixture proves display text, not pixels. Existing broad cardinal substring behavior and unknown-label fallback are intentionally preserved.
- **Commit message:** `fix(display): preserve compound direction labels [F11]`.
- **Rollback:** revert this pure helper extraction/correction and its two call-site substitutions; no wire compatibility change.

## Pass 7A — F14

**PASS**

- **Files changed:** NearbyStationsView.swift, new NearbyArrivalETA.swift, tests/nearby_arrival_identity_test.swift, test registration and reports.
- **Behavioral problem:** equal ETA values were identical SwiftUI row IDs.
- **Characterization:** two distinct existing arrival IDs both display 5 minutes; both remain distinct and keep their IDs when they become 4 minutes. Past/whole/fractional minute rounding also checked.
- **Production change:** carry the existing CTAArrival.id alongside its computed minutes and use Identifiable rows. No sorting, grouping, content or protocol changes.
- **Targeted tests:** nearby_arrival_identity_test PASS; old numeric IDs demonstrably collide in the fixture.
- **Broader tests:** 24 host PASS (11 Swift, 13 C++), one compiled-only, one manual; normal Xcode simulator build PASS.
- **Manual verification required:** none for identity mapping; optional equal-ETA UI visual smoke. Host tests do not render SwiftUI pixels.
- **Known remaining limitation:** relies on the existing arrival model's identity quality; does not redesign provider IDs.
- **Commit message:** fix(ui): use stable arrival row identity [F14].
- **Rollback:** local projection, view substitutions and test; no cross-platform dependency.

## Pass 7B — F13

**PASS** — user approved consistent 60-second Nearby UI recovery after the historical policy-only commit `0598a14`.

- **Files changed:** NearbyStationsViewModel.swift, tests/nearby_retry_policy_test.swift, PassResults.md and AggregateVerification.md. Existing test runner unchanged.
- **Behavioral problem:** an initial ordinary error stopped startup; periodic CTA/BART/MBTA errors stopped their loops; MTA retried but replaced previously loaded arrivals with an error/loading state.
- **Characterization added/used:** the existing test-only stepped timer compiles actual view-model control flow and production transit models. All four agencies now exercise two initial failures followed by success, two subsequent failures retaining the complete loaded state and original timestamp, later success with new data/date, exactly one attempt per clock advance, immediate user-triggered refresh replacing the old loop, stopRefreshing while asleep and during an active periodic fetch, cancellation during initial fetch, and provider CancellationError ending an invalidated periodic loop. The runner asserts that the production interval is still exactly 60 seconds. Small provider/environment doubles do not simulate networking or SwiftUI pixels.
- **Production change:** initial load always hands ordinary failure recovery to the existing loop unless the owning task was cancelled. Every agency uses non-loading periodic refresh. Ordinary periodic errors preserve a loaded state; without loaded data, the error remains visible. Errors are logged and the next iteration waits the same 60 seconds. No immediate retry, backoff, provider, fallback, BLE or background/device change. User-triggered findNearbyTrains and freshArrivalsForBLESend retain their immediate entry behavior; the latter is unchanged.
- **Targeted tests:** historical policy harness PASS before edits; new recovery fixture failed against old production at the initial-retry assertion; updated production PASS for CTA/MTA/BART/MBTA. Expanded in-flight and context-cancellation cases PASS.
- **Broader tests:** all 24 standard host harnesses PASS before and after; normal Xcode Debug simulator build PASS with no project/signing edits. Firmware unchanged, so its target build was not repeated; all 13 firmware host tests passed in the combined suite. Protocol fixtures unchanged.
- **Manual verification required:** none for the deterministic loop policy. Optional foreground UI smoke: load arrivals, interrupt networking across two refresh intervals, restore networking, verify retained rows/date and recovery; leave the view and confirm polling stops. This is not claimed as performed.
- **Known remaining limitation:** tests step the timer, not wall-clock scheduling or real networking. Retained arrivals retain their old timestamp and are not declared newly fresh. User-triggered loading/error presentation remains existing behavior. No new permanent-error taxonomy was introduced.
- **Intentionally terminal paths:** task cancellation/view teardown and periodic provider CancellationError still stop the old loop. The actual provider emits CancellationError on changed agency/location context; a new user/context refresh owns replacement work. Other serving failures have no existing UI-level permanent/terminal classification and can be retried at the normal cadence; persistent permission/configuration errors may therefore remain visible or logged until their cause changes.
- **Commit message:** `fix(ui): keep nearby refresh alive after transient failures [F13]` (this F13 commit).
- **Rollback:** revert only this F13 production/test commit to restore the previous policy and its matching characterization. No later cleanup changes are included. Historical report-only changes may need conflict resolution after future edits.

## Campaign disposition

Eleven reliability/UI passes and C1–C4 cleanup are committed separately. C5–C7 remain unstarted. The F13 policy blocker is resolved; existing hardware obligations remain. C3/C4 deletion rollback order is documented below.

The separate commits are bounded, but accumulating reports and a shared registry make several raw `git revert` operations conflict. F01 also overlaps later local BLE guards. Prepared reverse patches in `rollback/` preserve unrelated later changes; see AggregateVerification for their actual verification limits. F09 rollback removes its cross-session assertion from the later F10 integration fixture while preserving F10's render-certainty fix. No history has been squashed or rewritten.

| Pass | Finding | Commit | Targeted Tests | Full Suite | Manual Test Needed | Result | Rollback Safe |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1A | F01 | `d022b55` | Write wait/retirement ownership PASS | 18 host PASS | Required | PASS — MANUAL VERIFICATION REQUIRED | Bounded reverse patch; host-tested, see limits |
| 1B | F02 | `faa100f` | Source transition trace + Xcode; physical callbacks pending | 18 host PASS | Required | PASS — MANUAL VERIFICATION REQUIRED | Bounded reverse patch; host-tested, see limits |
| 1C | F03 | `5993694` | Source A/B trace + ownership helper PASS; physical callbacks pending | 18 host PASS | Required | PASS — MANUAL VERIFICATION REQUIRED | Bounded reverse patch; host-tested, see limits |
| 2 | F04 | `ef8e34d` | Cache fixtures PASS | 19 host PASS | No | PASS | Bounded reverse patch; host-tested, see limits |
| 3A | F05 | `708640f` | Actual controller simulator PASS | 19 host PASS | Required, two devices | PASS — MANUAL VERIFICATION REQUIRED | Bounded reverse patch; host-tested, see limits |
| 3B | F09 | `e21552d` | Diagnostic scope/retention PASS | 20 host PASS | Optional export | PASS | Bounded reverse patch; host-tested, see limits |
| 4 | F10 | `203159c` | Render evidence PASS | 21 host PASS | Optional export | PASS | Bounded reverse patch; host-tested, see limits |
| 5 | F12 | `fe53a58` | Deadline/refresh flow PASS | 22 host PASS | Optional wake | PASS | Bounded reverse patch; host-tested, see limits |
| 6 | F11 | `27fc013` | Direction fixtures PASS | 23 host PASS | Required visual label | PASS — MANUAL VERIFICATION REQUIRED | Bounded reverse patch; host-tested, see limits |
| 7A | F14 | `a7dc7a9` | Equal ETA identity PASS | 24 host PASS | Optional UI | PASS | Bounded reverse patch; host-tested, see limits |
| 7B | F13 | `fccebae` | Four-agency recovery/cadence/cancellation PASS | 24 host PASS; Xcode PASS | Optional foreground UI smoke | PASS | Local model/test revert; no later production dependency |
| 8A | C1 | `ee5977a` | Source/prose review; no code change | 24 host PASS | No | PASS | Documentation only |
| 8B | C2 | `1409782` | Exact commands/arguments/status JSON equality | 24 host PASS | No | PASS | Runner reporting only |
| 8C | C3 | `96b45c1` | Nearby characterization + Debug build PASS | 24 host PASS | Optional UI smoke | PASS | Revert C4 first for verbatim C3 restore |
| 8D | C4 | `676ca2d` | Reference proof; Nearby/transit tests; Debug + Release builds PASS | 24 host PASS; ESP32 compile PASS | No new hardware requirement | PASS | Local deletion reversal; C3 dependency noted |
| 8E | C5 | — | Not run | Not applicable | Not assessed | Not started — separate cleanup campaign | No change |
| 8F | C6 | — | Not run | Not applicable | Not assessed | Not started — separate cleanup campaign | No change |
| 8G | C7 | — | Not run | Not applicable | Not assessed | Not started — separate cleanup campaign | No change |

## Deliberately unchanged

- **C5–C7:** not requested in this follow-up. Grouping ownership, firmware experiments and formatter readability remain unchanged; no conditional deletion/relocation decision was inferred.
- **F06:** unsolicited developer-send framing; **F08:** setup/display-mode partial success; **F15:** freshness/retained-board contract; **F16:** station backfill; **F17:** platform identity/grouping; **F18:** ownership/authentication/security; **F19+:** provider/network policy. Explicitly outside scope.
- **F07:** shared location waiters was not in the authorized implementation list.
- Power architecture, BLE availability policy, renderer architecture, diagnostic firmware purge, provisioning, protocol versions and broad naming remain unchanged.

Remaining limitations are recorded under each implemented pass: host continuation tests do not establish OS radio behavior; valid-but-incorrect cache metadata is not repaired; diagnostic session IDs are not global physical-device identities; missing render evidence remains unknown; display fixtures do not prove pixels. No hardware success is claimed.

## Pass 8A — C1 documentation accuracy

**PASS**

- **Finding:** C1/F24, stale architecture and verification descriptions.
- **Files changed:** docs/IOS-STRUCTURE.md, docs/SETUP-BINDING.md, firmware README.md, tests/README.md, this report.
- **Behavioral problem:** none changed; stale prose could guide future work toward obsolete lifecycle/cache assumptions.
- **Characterization used:** source checks of FirmwareConfig, BleSession, DeviceProvisioning, BleIntegration, RefreshFlow, DisplayController, Serving sources and DEBUG guards. No new tests needed for prose.
- **Production change:** none. Corrected setup eligibility/pending preferences, current always-on BLE default, cloud/direct ownership, separate freshness clocks, release-used Debug files, ACK versus display completion and manual boundary. Marked firmware's old implementation notes as historical rather than claiming their old verification applies now.
- **Targeted checks:** source/prose and diff review PASS; four documentation files only before report addition.
- **Broader tests:** full 24-harness host suite PASS before/after; one compiled-only and one manual. No code/test/project settings changed; native build unnecessary for prose.
- **Manual verification required:** none added. Existing hardware obligations remain outstanding.
- **Known limitation:** historical firmware notes remain explicitly labelled history; documentation does not establish hardware success or fix F08 partial-save semantics.
- **Commit message:** cleanup(docs): align architecture and verification notes [C1].
- **Rollback:** documentation-only commit; no runtime dependency.

## Pass 8B — C2 host runner output

**PASS**

- **Finding:** C2/F29, opaque distinctions between compilation, execution and manual work.
- **Files changed:** tests/run_tests.py and this report.
- **Behavioral problem:** none; reporting obscured what a green run actually covered.
- **Characterization used:** saved pre-change results.json, then exact structural equality with post-change results including every compiler command, argument and status. No test semantics or fixtures changed.
- **Production change:** none. Added per-harness presence/run messages, compiled/executed totals, named passed/compiled-only/manual/failed lists, missing optional registrations, and explicit separate Nearby/theme harness inventory. Manual hardware checks remain labelled manual.
- **Targeted checks:** before/after JSON equality PASS; inspected summary: 26 registered present, 25 compiled, 24 executed/passed, 1 compiled-only, 1 manual; 2 separate harnesses not counted as run.
- **Broader tests:** 24 host PASS before/after; unchanged command order, timeouts, result JSON schema and exit criteria. No native rebuild needed for reporting-only Python changes.
- **Manual verification required:** none added.
- **Known limitation:** separate harnesses require their own commands; the historical manual renderer remains manual. Missing optional entries are reported, not turned into new failures.
- **Commit message:** cleanup(tests): report host harness execution clearly [C2].
- **Rollback:** runner-output/report-only commit, independent of production behavior.

## Pass 8C — C3 unused Nearby dependencies

**PASS**

- **Finding:** C3/F25, obsolete nearby-view ownership remnants.
- **Files changed:** NearbyStationsViewModel.swift and this report.
- **Behavioral problem:** none; inactive local owners obscured the actual serving provider.
- **Characterization used:** reference search found only declarations of locationService, stationRepository, transitCache and private nearestStations. Reviewed constructors: unused LocationService only creates/configures its private manager, with no request/permission prompt; delegate requests require an absent continuation or false authorization flag. CTA repository sets encoder options; cache initialization has no fetch. Active serving owns its own location source. Existing four-agency Nearby harness used unchanged.
- **Production change:** removed those three unused properties, the unused private helper and its now-unused CoreLocation import. Grouping/provider/refresh behavior untouched; one logical deletion group.
- **Targeted tests:** Nearby recovery/cadence/retention/cancellation characterization PASS before/after; normal Xcode simulator build PASS.
- **Broader tests:** 24 host PASS before/after, one compiled-only, one manual.
- **Manual verification required:** none added; optional Nearby UI smoke only.
- **Known limitation:** the test does not render SwiftUI or exercise live location; source ownership and native compilation establish the deletion boundary.
- **Commit message:** cleanup(ui): remove unused nearby dependencies [C3].
- **Rollback:** restore 14 removed lines; no active provider or grouping change. After C4, revert C4 first for the removed cache property to compile. This deletion dependency is not a conflict-free independent raw revert.

## Pass 8D — C4 dormant direct provider/cache

**PASS**

- **Finding:** C4/F26, dormant direct-provider/cache chain obscuring the active serving path.
- **Files changed:** Data/LiveTransitProvider.swift, deleted Data/TransitDataCache.swift, Location/LocationService.swift, tests/nearby_retry_policy_test.swift (obsolete cache double only), tests/support/HostSupport.swift (comment only), docs/IOS-STRUCTURE.md, docs/ETA-SHADOW.md and this report.
- **Behavioral problem:** none intentionally changed. Reference proof found no DirectTransitPayloadProvider constructor in app, DEBUG code, tests or developer commands. After C3, cache references were confined to that dormant class and the live location freshness constant; the Nearby test's empty cache double was obsolete.
- **Characterization used:** repository-wide symbol searches, constructor review, unchanged shared error/protocol declarations, existing transit/formatter/CTA fixtures and four-agency Nearby characterization. The location acceptance value remains exactly 30 with the same half-open age predicate and accuracy checks; no new UIKit mocking added for a constant relocation.
- **Production change:** deleted only the dormant DirectTransitPayloadProvider class and TransitDataCache file. Preserved TransitPayloadProvider and LiveTransitError in their existing file; moved the 30-second location-only constant to private LocationService ownership. No type/file rename, fallback change or provider-policy change. Active LegacyTransitArrivalSource, LegacyArrivalAdapter, ArrivalComparisonModels, station repositories, API clients and shared models remain.
- **Targeted tests:** transit/formatter/cache/protocol host fixtures PASS; Nearby characterization PASS. Both normal Debug and Release Xcode simulator builds PASS (filesystem-synchronized source target, unchanged project/signing configuration).
- **Broader tests:** 24 standard host PASS; one compiled-only and one manual. Final ESP32-C6 target compile PASS, unchanged firmware, no upload; protocol goldens and generated payload bytes identical to baseline.
- **Manual verification required:** none added by unreachable-code deletion; existing BLE/theme/display obligations remain. Optional normal Nearby/device refresh smoke can accompany them.
- **Known limitation:** source reachability and target compilation establish the deletion; host tests do not simulate real provider fallback or CoreLocation. Historical migration text remains history with updated current ownership.
- **Commit message:** cleanup(transit): remove dormant direct provider and cache [C4].
- **Rollback:** C4 itself restores the original class/cache and constant owner. For a verbatim rollback of C3 as well, revert C4 first: C3's removed cache property refers to the deleted type. Shared report edits may conflict; do not call that pair conflict-free or dependency-free. No behavioral change requires a data migration.

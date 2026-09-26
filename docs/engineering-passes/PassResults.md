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

**BLOCKED — DESIGN DECISION REQUIRED**

- **Files changed:** tests/nearby_retry_policy_test.swift, tests/run_nearby_retry_policy_test.py and this report. No production change.
- **Behavioral problem:** periodic MTA errors are caught by loadNearbyStationsAndRefresh and the loop continues; periodic CTA/BART/MBTA errors reach the outer catch and terminate the loop. Initial errors terminate startup for every agency.
- **Characterization:** compile production view-model control flow and actual transit models with small provider/environment doubles. A test-only generated source replaces exactly one 60-second sleep expression with a stepped clock. No production seam, source edit, UI or networking framework added. All four agencies are exercised for initial failure, periodic failure, recovery or termination, plus cancellation. The generated source and binary remain outside the checkout.
- **Targeted tests:** stepped-clock characterization PASS. Two preliminary real-timer attempts failed their timing assumption (MTA's first tick had not occurred by the assertion); those are retained as failed experiments, not counted as passed integration coverage. The deterministic test establishes control flow, not OS timer accuracy.
- **Production change:** none. Source/comments/review do not establish whether the discrepancy is intentional. A retry policy decision is necessary; no inference from MTA's current behavior is treated as authorization.
- **Broader tests:** final standard host suite 24 PASS; separate policy harness PASS. Xcode simulator and ESP32-C6 builds PASS.
- **Manual verification required:** none for an unchanged policy; a future intentional policy fix should check foreground nearby refresh for the selected agency.
- **Known remaining limitation:** MTA and the other three agencies retain different periodic-error behavior; background device refresh is not changed or covered by this UI harness.
- **Commit message:** test(ui): characterize agency retry policy; await decision [F13].
- **Rollback:** test/report additions only, no product behavior to revert.

## Campaign disposition

Ten production passes are committed. F13 is characterized but requires a product decision. C1–C7 have not started: the requested sequential gate prevents continuing through an unresolved policy pass. This is a partial campaign with an explicit stop, not a claim that the cleanup campaign is complete.

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
| 7B | F13 | `0598a14` | Stepped-clock policy PASS | 24 host PASS | No change | BLOCKED — DESIGN DECISION REQUIRED | Test/report only |
| 8A | C1 | — | Not run | Not applicable | Not assessed | BLOCKED — prior-pass gate | No change |
| 8B | C2 | — | Not run | Not applicable | Not assessed | BLOCKED — prior-pass gate | No change |
| 8C | C3 | — | Not run | Not applicable | Not assessed | BLOCKED — prior-pass gate | No change |
| 8D | C4 | — | Not run | Not applicable | Not assessed | BLOCKED — prior-pass gate | No change |
| 8E | C5 | — | Not run | Not applicable | Not assessed | BLOCKED — prior-pass gate | No change |
| 8F | C6 | — | Not run | Not applicable | Not assessed | BLOCKED — prior-pass gate | No change |
| 8G | C7 | — | Not run | Not applicable | Not assessed | BLOCKED — prior-pass gate | No change |

## Deliberately unchanged

- **F13:** choose continued 60-second nearby retry for all agencies, stop-until-user-refresh for all, or retain/document the existing difference. No production policy is inferred.
- **C1–C7:** held at the explicit sequential gate. No documentation cleanup, runner redesign, dependency/provider/experiment deletion, grouping relocation or formatter cleanup was performed. Their merits have not been reassessed during this campaign.
- **F06:** unsolicited developer-send framing; **F08:** setup/display-mode partial success; **F15:** freshness/retained-board contract; **F16:** station backfill; **F17:** platform identity/grouping; **F18:** ownership/authentication/security; **F19+:** provider/network policy. Explicitly outside scope.
- **F07:** shared location waiters was not in the authorized implementation list.
- Power architecture, BLE availability policy, renderer architecture, diagnostic firmware purge, provisioning, protocol versions and broad naming remain unchanged.

Remaining limitations are recorded under each implemented pass: host continuation tests do not establish OS radio behavior; valid-but-incorrect cache metadata is not repaired; diagnostic session IDs are not global physical-device identities; missing render evidence remains unknown; display fixtures do not prove pixels. No hardware success is claimed.

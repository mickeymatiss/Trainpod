# Firmware reliability: update and display ownership

## Audit before refactor

Boot and refresh both used `takeTransitPayload → decodeArrivalPayload →
ArrivalScreen::setPlatforms → acknowledgeTransitApplied → finishTransitRefresh`.
The data transport/parser were shared, but first data also entered
`completeStartupWithBoard → fullBoardRenderPending → drawTheme`; subsequent
updates entered dirty/incremental drawing. A failed first framebuffer allocation
left a flag retried every UI tick. Startup completion no longer gated BLE, but
physical drawing blocked the very loop responsible for servicing BLE and inputs.

Main-loop TFT entry points were initialization (`gfx.begin`, rotation, setup
screen, `ArrivalScreen::begin`), `tick` (full/incremental/ETA/page/spring rendering),
button feedback, navigation, wake/resume, standby/clearSpring, UI style updates,
and effects commands. BLE settings callbacks queued their work, but the app's
settings handler synchronously called `themeChanged` before returning.

There was no explicit main display mutex; GFX's SPI bus mutex and hardware busy
waits were reachable synchronously. Its APB frequency-change callback also waits
for SPI, so downclocking the app could block behind a stuck renderer even after
moving drawing to another task. Serial output had a shared indefinite mutex.
RefreshFlow retried the same request every five seconds without an overall update
deadline. Connection/subscription, response assembly and requested/paused flags
controlled future requests; display state must not join those conditions.

## Ownership after refactor

- `DisplayController`'s main-loop facade owns the authoritative board, selection,
  pagination/freshness timers, input and suspension state. A valid parsed board is
  committed here before any render request is published.
- `TrainPodRender` alone initializes/accesses TFT and runs `ArrivalScreen` drawing,
  setup screens, visual effects and animations. ArrivalScreen holds an observed
  snapshot; it no longer advances application selection or handles startup state.
- The SPSC triple buffer provides one replace-latest pending snapshot, one worker
  slot and one producer slot. It transfers indices atomically, with no shared
  display mutex and no string copying/allocation inside a lock. Superseded pending
  snapshots do not accumulate. UI tuning has a separate bounded, nonblocking
  four-command queue.
- Snapshots include the board, selected page/platform, timestamps, connection,
  battery, display mode, theme, setup state, button state and suspension. Palette
  persistence stays on the app loop; render colors use a worker-owned copy.
- Renderer logs use a bounded zero-wait queue drained by the app. Rendering never
  takes the app's Serial mutex. Dropped diagnostic fragments are reported.
- CPU stays at 160 MHz while the renderer exists to avoid APB/SPI lock coupling.
  This intentionally trades the former 10 MHz idle power saving for containment.
  Backlight dimming, standby and BLE lifecycle policies remain in place.

## One transit pipeline

`runTransitUpdate(reason)` begins an episode before normal BLE connection setup.
Startup, periodic refresh, retries after failures, and `transit refresh` use the
same request, assembly, parser, commit and render submission code. The old empty
refresh-display callback and boot-only render flags are removed.

Stages are `UPDATE_BEGIN`, `BLE_READY`, `REQUEST_SENT`, `RESPONSE_RECEIVED`,
`STATE_COMMITTED`, `RENDER_REQUESTED`, then `UPDATE_COMPLETE`. Logs include the
transaction ID and millisecond timing; render submission includes its generation.
`UPDATE_FAILED` covers invalid data, enqueue failure, disconnect and pause;
`UPDATE_TIMED_OUT` covers session/update deadlines. The whole episode has a
45-second deadline, including connection setup. Failures impose a five-second
cooldown before a new `RETRY` episode. Existing five-second retransmissions keep
the same wire transaction ID within the bounded episode, preserving phone-side
response caching and partial-frame assembly. No separate startup protocol exists.

Completion means data is committed and a latest-state snapshot is published;
it does not mean the screen succeeded. A missing renderer is reported separately
and cannot turn valid transit data into a failed fetch. A payload already handed
off to the main loop can finish committing even if BLE disconnects during parse.

## Render containment and limits

Each generation logs `RENDER_BEGIN`, `RENDER_COMPLETE`, `RENDER_FAILED`, or
`RENDER_SUPERSEDED`. Completion covers the physical transfers and animations.
The app independently reports a five-second stall using atomic progress metadata.
Returned allocation/init errors stop the generation; subsequent snapshots may
retry. There is no every-loop retry of a failed generation.

The worker runs at idle priority and yields between frames. The supplied stalled
render simulation yields while holding no application lock. A non-returning SPI
operation is diagnosed without deleting a task that might own the SPI lock;
main/BLE continue when the scheduler can preempt that task. There is deliberately
no claim to recover from a driver that disables interrupts indefinitely, a global
hardware failure, or total heap exhaustion. GFX's void transfer APIs cannot detect
panel corruption or verify that pixels physically appeared. A partial transfer
may leave a partially drawn screen; the next meaningful snapshot forces a full
repaint after a reported failure. Real power/driver behavior needs hardware checks.

## Optional serial fault controls

- `render slow 3000`: delay each newly consumed snapshot by three seconds.
- `render fail`: fail the next generation once, before touching TFT.
- `render stall`: stop progress in the renderer; app reports a stall after five seconds.
- `render resume`: release the injected stall and clear artificial delay.
- `render slow 0`: clear artificial delay.
- `transit refresh`: request data through the same pipeline while transit is active.

All controls are RAM-only. Normal inactivity still dims/enters standby, so keep the
physical device active while observing repeated refreshes. During a slow/stalled
render, update completion and button/state handling should continue; the newest
pending snapshot wins after rendering resumes. `render resume` releases only the
injected stall, not a genuinely hung driver. No builds, tests or flashing were run.

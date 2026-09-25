# TrainPod initial setup and device binding V1

## State and radio availability

`DeviceProvisioning` owns `Unprovisioned`, `SetupReady`, `Provisioned`, and a
fail-closed `StorageError` state. Missing binding state enters setup. Permanent
identity remains in the unchanged `DeviceIdentity` module.

An unprovisioned device starts normal-service advertising at boot with unlimited
duration (`start(0)`). Button-down opens a 60-second eligibility window; it never
starts advertising. Window expiry only clears eligibility. The BLE session's
normal end/abort/completion paths cannot shut down unprovisioned advertising.
The setup update path bypasses the 15-second session timeout and normal refresh,
standby, reconnect and manual-window timers, and re-arms advertising after link
changes or transient start failures. Disconnects in setup return directly to
advertising without tearing down the BLE stack. Advertising is re-enabled after
a connection too; only one active setup client is accepted at a time.

The setup screen shows SET UP / Open TrainPod app / Press button, changing to
Ready to connect during the window. Setup keeps the display awake at the current
brightness cap. Its radio rule does not depend on display state. Transit refresh
and normal navigation are paused while unprovisioned. After persistence succeeds,
a 60-second radio grace period permits lost-result recovery, then the existing
normal lifecycle resumes. Radio/identity-storage faults still require successful
hardware initialization; the software does not fabricate an ephemeral identity.

## Durable state

Firmware stores one versioned 52-byte NVS blob in namespace `tp_binding`, key
`record`: 4-byte version (1), 16-byte app installation UUID, 32-byte binding key.
Existence of a valid complete blob means provisioned. NVS set+commit occurs on
the Arduino loop, not the BLE callback. Existing malformed/unreadable records are
preserved and claims fail closed. Binding and permanent identity have separate
namespaces. Normal firmware uploads must preserve NVS.

The app stores one atomic Keychain JSON item (`com.trainpod.local-binding.v1`,
account `installation`, non-synchronizing, AfterFirstUnlockThisDeviceOnly):
installation UUID, and either PendingTrainPodBinding or BoundTrainPod.
Credentials are generated once; pending is saved before the first claim write.
Promotion replaces pending with bound in that same item. Keychain read/write
failures do not cause a new secret or erase existing binding records. ThisDeviceOnly
credentials do not migrate to another phone. Keychain state may survive app
reinstallation; local removal is explicit.

## Separate setup GATT interface

All characteristics use the existing service
`7A1C0001-8F4A-4D2B-9A57-1C2D3E4F5001`.

| Characteristic suffix | Purpose | Properties | Value |
| --- | --- | --- | --- |
| `0002` | Existing transit transport | Unchanged | Existing protocol |
| `0003` | Permanent identity | READ | `TP-` plus hexadecimal ID, unchanged |
| `0004` | Setup status | READ | `[1, state]`; state 0 unprovisioned, 1 ready, 2 provisioned, 3 storage fault |
| `0005` | Setup command | WRITE with response | Four bounded frames described below |
| `0006` | Setup result | READ, NOTIFY | `[1, token LE32, resultCode]` (6 bytes) |

Suffixes replace the final four digits of the first UUID group: e.g. status is
`7A1C0004-8F4A-4D2B-9A57-1C2D3E4F5001`.

Command bytes: `[operation, token LE32, frameIndex, credentialChunk]`.
Operation 1 = initial claim; 2 = credential recovery. A random nonzero 32-bit token
correlates the response. Credential payload is UUID bytes (16) then key (32).
Frame indexes 0,1,2 each carry 14 bytes; frame 3 carries 6. Thus each write is at
most 20 bytes and fits the default ATT payload. Writes are sequential with BLE
write responses. The fourth complete frame triggers processing. Fragments must
arrive in order, in one connection epoch, with the same operation/token, within
10 seconds. Partial/malformed/old-connection frames never persist a binding.
A dropped frame or full queue times out at the app and retries with the same
pending credentials. The app polls the result characteristic and checks the token;
it never treats a BLE write acknowledgement as binding success.

Result codes: 0 no result, 1 success, 2 setup window inactive, 3 already provisioned,
4 recovery credentials rejected, 5 storage failure, 6 malformed request.
Initial claims require an active window at processing time and an unprovisioned
device. A second claim is rejected even with identical credentials. Operation 2
accepts only an exact stored UUID/key match and never overwrites ownership or
requires a fresh button press. It works after disconnect, app restart or reboot.
Secrets never go through transit raw logging or a readable characteristic.

V1 uses local credential comparison over BLE. It does not add BLE link encryption,
a challenge-response protocol, cloud accounts or a security boundary around the
legacy transit characteristic. Those are separate future hardening decisions.

## App flow and reconnect behavior

Until bound, the single setup card replaces Main/Dev UI and normal BLE services
are gated, including restored connection intents. A separate setup central scans
for the existing service and briefly connects to candidates to read identity and
status. This read-only probing is necessary because setup state is not advertised;
proximity alone never sends a claim. Non-ready candidates are released and retried,
so a nearby device can be discovered before its button is pressed.

Ready status permits creation of durable pending credentials and initial claim.
A pending binding restricts further attempts to the same physical deviceId. If
that device reports provisioned, the app sends recovery instead. If it remains
unprovisioned, the app waits for readiness and reuses the same credentials.
Success promotes storage, shows a short acknowledgement, then starts normal BLE.

Bound startup uses CBPeripheral.identifier as a hint only. The permanent identity
is read and compared on every connection/restoration before enabling transfer,
notifications/refresh handling or clock sync. Mismatches are disconnected and
service scanning continues. The app can probe other peripherals to read identity;
it cannot enable their transit data path. Missing/invalid identity fails closed.

## Explicit reset APIs

- Firmware: `DeviceProvisioning::shared().clearProvisioning()` on the Arduino
  loop returns success/failure. It erases only the binding blob, closes eligibility,
  and returns to setup. It never erases or regenerates deviceId. No physical or
  remote reset command is introduced.
- App: `BLERuntime.shared.forgetLocalBinding()` disconnects normal clients,
  clears only pending/bound credentials (preserving installation UUID), and starts
  setup. It does not remotely unbind a provisioned device. No settings UI added.

## Manual acceptance checks

No builds, tests or flashing were run for this change, per the user's preference.
Use a fresh/explicitly unbound board and app to check:

1. Boot discovery before any button press; leave idle beyond normal 15/30/60-second
   timeouts and verify availability. Connect/disconnect during setup and repeat.
2. Press once, observe ready; wait over 60 seconds and verify advertising remains
   active while initial claim eligibility expires.
3. Complete setup; verify persisted identity unchanged and both sides skip setup
   after restart. Verify normal transit, themes, clock and display behavior.
4. Drop the connection after the fourth claim frame but before result receipt;
   restart the app and recover automatically with the saved pending credentials.
5. Use a second app to attempt a claim of the provisioned board; verify rejection.
6. Present another TrainPod during normal reconnect; ensure no transit write or
   clock sync occurs unless its permanent ID matches the registered record.
7. Clear firmware provisioning explicitly and verify deviceId stays unchanged.
   Clear local app binding separately for a fresh setup round.

References: [NimBLE unlimited advertising](https://h2zero.github.io/NimBLE-Arduino/class_nim_b_l_e_advertising.html),
[Apple Keychain accessibility](https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlockthisdeviceonly).

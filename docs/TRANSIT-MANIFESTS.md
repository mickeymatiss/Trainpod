# Static transit manifests

The manifest layer uses one implementation for NYC and CTA. `TransitAgency.systemID` maps the existing MTA/CTA preference to backend IDs `nyc`/`cta`. `KeyTrainConnectApp` owns `TransitManifestManager` as a `StateObject`, injects it through the environment, and calls synchronous `activate(systemId:)` on launch and city changes. Activation exposes the local cache and returns without awaiting HTTP. A manager-owned utility task independently checks for updates.

## Delivery URL

`TransitManifestBaseURL` in `Trainpod/Info.plist` is configured to `https://d2xo1bocmox64v.cloudfront.net`. The client appends `/systems/{systemId}/system.json`. This public read-only CloudFront endpoint uses an OAC-authenticated private S3 origin. No credentials are embedded in the app.

Both systems were downloaded, validated, and persisted using the actual Swift manifest manager/client. Conditional ETag requests returned 304 for each. The full iOS simulator build also passed. Manifest failures remain invisible background maintenance; cached data and existing app behavior remain available.

## Access

```swift
@EnvironmentObject private var manifests: TransitManifestManager

// Shared static metadata, with backend-provided route colors.
let station = manifests.currentManifest?.stations[stationID]
let route = manifests.currentManifest?.routes[routeID]
```

`currentManifest` and `currentSystemID` are observable. `isRefreshing` and `lastError` are diagnostics only, not published UI state. Refresh errors do not erase cached data. A completed request for a formerly active city may update that city's cache but cannot change the current city's manifest/error/loading state. Duplicate in-flight requests for a system coalesce.

## Files

- `Products/Transit/Models/TransitSystemManifest.swift`: backend v1 Codable models. `generatedAt` is a required string; `sourceVersion`, colors, and direction are optional. Colors retain the backend `#RRGGBB` format.
- `Products/Transit/Systems/TransitSystemID.swift`: stable IDs and bridge to the existing agency selection.
- `Products/Transit/Manifest/TransitManifestClient.swift`: URL construction, conditional HTTP, 200/304 handling.
- `TransitManifestValidator.swift`: generic schema, ID, coordinate, route-reference, timestamp, and color validation.
- `TransitManifestCache.swift`: per-system persistent cache.
- `TransitManifestManager.swift`: cache-first app state, refresh, validation, and last-known-good behavior.

Downloaded candidate decoding, validation, encoding, and atomic writes run in a detached utility task, away from the main actor. A 304 does not rewrite disk or publish unchanged state; failures are logged without UI invalidation. The client uses a 20-second request timeout and 30-second total resource timeout.

The cache is `Application Support/TransitManifests/{systemId}/system.json`. It stores a local envelope containing `manifest` and `etag` in one atomic write, rather than writing JSON and UserDefaults independently. The decoded network model has no cache/UI fields. This prevents a crash from pairing an old manifest with a new ETag. Corrupt caches are ignored, so their ETags are never used. A 304 without a usable local copy gets one unconditional retry.

This P0 exposes static metadata to app state. Existing station selection, direct arrival clients, BLE payloads, and their refresh behavior are unchanged. No new timer, background refresh, manual refresh control, or UI redesign is added.

## Verification

The full iOS simulator build passed with Xcode 27. Existing setup-controller concurrency and asset warnings remain outside this change. A standalone Swift harness checks the actual backend NYC/CTA fixtures, independent cache records and ETags, HTTP headers/200/304/errors, offline restart, invalid replacement preservation, failed disk writes, an out-of-order city-switch response, synchronous activation while HTTP is suspended, and zero observable updates for 304/failure.

Run the harness from the repository root, supplying downloaded backend manifests:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc \
  Trainpod/Products/Transit/Manifest/*.swift \
  Trainpod/Products/Transit/Models/TransitSystemManifest.swift \
  Trainpod/Products/Transit/Systems/TransitSystemID.swift \
  tests/transit_manifest_test.swift -o /tmp/transit-manifest-check
/tmp/transit-manifest-check /path/to/nyc-system.json /path/to/cta-system.json
```

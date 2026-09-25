# Cloud ETA serving and reliability checks

Normal CTA and NYC requests now use the generic normalized cloud source, joined to the locally cached manifest and adapted to the existing arrival-board model and TP2 serializer. The BLE wire format is unchanged.

Cloud fetch/decode/reference failures, unavailable manifests, unusable station boards, serialization limits, and source age of 180 seconds or more trigger direct-provider fallback. The existing CTA/MTA clients remain independent. A cloud snapshot may be reused in memory for 20 seconds; freshness always uses its source timestamp.

Successful cloud serving schedules a background direct-provider check using the same canonical station IDs and coordinates. Serving does not await that check. One comparison can run at a time to bound upstream traffic. Results are observational, held in memory, and logged without full arrival payloads. There is no historical database or analytics backend.

## Developer controls

Open **Dev → Arrival Comparison & Random Test**. The existing station-level comparison links also work.

- Choose CTA or NYC, then tap **Random Test** to generate a location and run the normal serving/fallback path with background comparison.
- **Simulate Chicago** and **Simulate NYC** switch cities and immediately run a random request.
- Sampling squares are 2, 4, or 6 miles wide (default 4), using TransitHelpers centers: Chicago 41.900, -87.655; NYC 40.745, -73.977. The same latitude/longitude conversion and six-decimal rounding are preserved. These are city-core squares, not land or coverage guarantees.
- **Use Real Location** clears the session override and requests current location.
- Simulation also affects device requests in Debug builds until cleared or the app restarts. Release builds use actual device location and contain no simulation/comparison controls.

The screen shows location, selected stations, serving source, fallback status, independent source errors/timestamps, cloud source age, matched and unmatched counts, ETA deltas, and destination/platform mismatch counts. Approximate matches remain labeled. Timing differences and legacy result truncation can produce unmatched predictions without proving either source wrong.

No automatic synthetic loops or optional batch runner were added. If a comparison is already in flight, another is skipped; the screen indicates that a refresh is needed.

## Code boundaries

- `Serving/TransitServingCoordinator.swift`: cloud primary, direct fallback, independent validation.
- `Serving/CloudTransitArrivalSource.swift` and `LegacyTransitArrivalSource.swift`: common arrival-source protocol.
- `Location/TransitLocationProvider.swift`: real/debug location boundary.
- `Debug/TransitLocationSimulator.swift`: TransitHelpers coordinate-generation port.
- `Debug/ArrivalComparison*`: reused matcher and extended developer screen.

The original direct payload provider is retained as `DirectTransitPayloadProvider`; the existing `LiveTransitProvider` interface now delegates to cloud serving. Backend generators, provider clients, device firmware, and BLE protocol were not changed by this migration.

Validation is limited to compilation; no automated tests or live random-location runs were performed for this task.

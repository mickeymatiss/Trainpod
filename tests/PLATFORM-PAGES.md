# Platform payload and paging checks

This document supersedes the older instructions naming a separate Arduino checkout and obsolete page timing/model fields.

Run `python3 tests/run_tests.py` from this repository. The runner builds the Swift formatter/MTA harnesses, writes their payloads outside the repository, then passes those exact bytes to the firmware decoder harnesses. It also checks the fixed shared fixtures in `tests/fixtures/protocol`.

Current source locations: `KeyTrain Connect.xcodeproj`, `Trainpod/Products/Transit`, and `arduino/sketch_cta_ble_demo`. Only that checked-in firmware is covered here; upload provenance for a different local sketch must be checked separately.

The current TP2 contract retains a checksum footer, four platform slots, at most nine arrivals per platform, explicit distance value/unit, and a 2048-byte maximum. Standard/compact pages show three/six arrivals. First-page dwell is eight seconds and subsequent-page dwell six seconds. Shared fixtures characterize these current behaviors; they do not redesign the protocol.

See `tests/README.md` for limits and `tests/MANUAL_SMOKE_TESTS.md` for real-device rendering/navigation/communication checks.

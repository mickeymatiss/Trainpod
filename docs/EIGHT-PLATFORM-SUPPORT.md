# Eight-platform board support

This is a separately authorized capacity feature after the bounded cleanup campaign.

The phone now sends up to four platform groups per station, retaining the two-station limit and a maximum of eight groups overall. The firmware ArrivalBoard fixed array increases from four to eight. Those three constants are the entire production diff: no PlatformDisplay fields, parser algorithm, renderer, navigation, grouping identity or BLE framing change.

The existing TP2/P1 representation, checksums, 2,048-byte payload limit and nine-arrival maximum per platform remain. Dense eight-platform boards may carry fewer arrivals because the existing formatter removes furthest arrivals until the payload fits. This does not increase the over-the-air byte budget. Existing one-to-four-platform golden bytes are unchanged.

Install the new firmware before using the new iOS build for a board with more than four platforms. The previous firmware rejects oversized platform counts; there is no capacity negotiation. The updated firmware continues accepting older smaller boards. No erase-all-flash or settings reset is needed.

## Verification

- Baseline: 24 host harnesses PASS. New capacity expectations failed against the old limits.
- After: 25 host harnesses PASS; one compiled-only network harness and one manual legacy renderer remain separate. Nearby retry characterization also PASS.
- The Swift fixture supplies Clark/Lake and a second station with East/North/South/West, verifies station-major ordering, empty known directions and two-station selection. Long-name nine-arrival fixtures preserve all eight headers within the unchanged byte cap.
- The generated Swift eight-platform payload is parsed by the firmware host harness. It checks each station/direction, platform wrap, direction preservation across station changes and refresh, standard/compact page counts, ninth-platform rejection without replacing retained state, checksum rejection and existing P1 framing with 20/244-byte chunks.
- Existing shared protocol golden files and generated platform.txt/mta.txt match the pre-feature baseline byte for byte. The old five-platform rejection test now rejects nine, and the MTA mixed-axis case accepts four while still rejecting five per station.
- Normal Xcode Debug simulator build and ESP32-C6 target compilation PASS. No project/signing/build configuration edits or upload. The initial new C++ test used a nonexistent header helper; it was corrected to the production envelope helper before verification passed.

Manual check remains: load a real four-direction station, cycle all directions, switch stations, verify standard/compact paging and successful repeated refresh. The fixture proves capacity and transport, not the availability or correctness of upstream Clark/Lake metadata. This change does not create missing platforms or redesign physical-platform grouping. Firmware fixed storage grows with the capacity; target compilation is not evidence of physical heap/stack headroom under sustained use.

Rollback: revert this feature commit on both phone and firmware as a pair, or restore the phone first so it stops sending larger boards before downgrading the firmware. The preceding cleanup commits remain separate.

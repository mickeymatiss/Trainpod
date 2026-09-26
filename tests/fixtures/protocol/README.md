# Release 1 shared protocol fixtures

`inputs.json` describes synthetic phone-side arrivals. Swift builds real production DTOs and compares `LiveTransitFormatter.payload` byte-for-byte with the checked-in `.tp2` files. Firmware reads those **same files**, checks decoding/counts and retained-board behavior. `index.tsv` is the tiny firmware expectation table, not a second parser implementation.

| Fixture | Contract protected |
|---|---|
| cta | Station annotation removal, alphabetical direction ordering, three sorted arrivals in each of two platforms, miles |
| mta_empty | MTA labels/colors, three sorted arrivals and an explicitly empty opposite platform, feet |
| agencies | BART/MBTA-style source-provided route names/colors and two station identities |
| long_names | 48-byte station/destination, 20-byte route limits and compound direction normalization |
| identity | Distinct source IDs with identical displayed station/direction names; documents current firmware selection of the last matching display identity on replacement, not a desired redesign |
| near_limit | 2016-byte payload, four platforms, long fields; tail pruning leaves 5/5/5/6 arrivals. This asymmetry characterizes current tie-breaking. One more 81-byte arrival exceeds the cap. |
| bad_checksum | One changed body byte without updating the footer; rejects atomically |
| incomplete | Truncated footer; rejects atomically |
| bad_record | Correct footer but an arrival before any platform; rejects atomically |
| unavailable | Exact special unavailable message; leaves the previous board intact |

`cta.header` is a 19-byte P1 response header: boot `0x12345678`, request `7`, the CTA payload length, ceiling(length/20) chunks, CRC32; integers are little endian. Swift must reproduce it, and C++ must assemble its payload unchanged. FNV footer/CRC bytes were independently calculated for these synthetic bodies. The near-limit expected body was reviewed against release 1 output before freezing its explicit counts.

These fixtures use LF and UTF-8/ASCII bytes. Do not normalize tabs/newlines or auto-update goldens during a test run. There is no live transit dependency. The input JSON supplies minute offsets; see the formatter's clock guard in the test README.

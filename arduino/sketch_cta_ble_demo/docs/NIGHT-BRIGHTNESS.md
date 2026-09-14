# Night brightness

Active brightness defaults to the existing daytime PWM level, 80 out of 255. From 22:00 inclusive to 07:00 exclusive in the phone's local time, it is capped at 50. Before local time is known, the cap is also 50. The backlight starts at zero and fades to the capped target; there is no daytime-brightness startup step.

Inactivity dimming remains 5 (or less if the configured active level is lower), and standby remains off. Night settings never wake the screen or reset inactivity. Clock sync and schedule changes retarget the existing one-second smooth backlight fade, independently of screen rendering.

The phone sends a 16-byte `T2` clock packet over the existing clock-sync path: `T2`, unsigned little-endian Unix milliseconds (8 bytes), session ID (4 bytes), signed little-endian UTC offset in minutes (2 bytes). This still fits the default ATT payload. The device validates the date, session, and offset before using them. Old 14-byte `T1` packets remain accepted for diagnostics but cannot unlock daytime brightness without a known local offset.

The local clock advances using 64-bit monotonic device uptime. Every new phone sync refreshes the offset (including the phone's current daylight-saving offset). After 24 hours without a valid sync it becomes unknown and returns to the night cap. Nothing is persisted across reboot. A timezone/DST change is learned on the next phone clock sync.

Serial, 115200 baud, newline terminated:

- `night status` — local clock or unknown, configured hours and levels, current active target.
- `night brightness 50` — night/unknown cap, range 0–255.
- `night day 80` — daytime level, range 0–255.
- `night start 22` — first night hour, range 0–23.
- `night end 7` — first daytime hour, range 0–23.
- `night reset` — defaults, retaining the current clock sync.
- `night help` — commands and ranges.

Equal start/end hours mean night all day. Night brightness never exceeds the configured daytime level. These settings are RAM-only and independent of visual-effect presets/reset. Rebuild/install iOS and upload the firmware together to enable automatic local-time behavior; firmware alone stays safely capped until it receives T2.

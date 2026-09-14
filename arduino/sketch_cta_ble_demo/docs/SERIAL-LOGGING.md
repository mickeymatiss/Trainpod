# Serial log levels

At 115200 baud with newline endings, send `log info` for the default quiet output, `log debug` for detailed traces, or `log status` to inspect the filter. The choice is RAM-only. Logger-managed application lines have `[INFO]`, `[DEBUG]`, or `[WARN]` for host-side filtering too. Info mode keeps warnings visible.

Info shows a single BLE-connected message, a single accepted arrival-board message, reactions to serial commands (including errors/help/status and requested summaries), and the final screen-dark event after the PWM fade actually reaches zero. The screen-dark line describes standby accurately: the CPU is still awake; firmware does not enter deep sleep.

Debug contains advertising, sessions, disconnect lifecycle, refresh retries/data age, transfer/chunk/ACK details, normal power transitions, button navigation, and render logs. `raw on` / `verbose on` still control whether detailed packet data is collected; use `log debug` to see it. Allocation, export, storage, invalid-payload, and other reported failures remain warnings.

Diagnostic records are still retained for export. Routine lifecycle/transport records now carry Debug severity, while accepted data and BLE connection remain Info. The serial verbosity filter does not discard diagnostic history. Identity startup messages use the exact `[IDENTITY]` format directly and remain visible. Framework/ROM output before the application starts is also outside this logger.

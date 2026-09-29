#pragma once

// Optional Mac LCD calibration. Set to 0 to compile it out.
// A compiler -DKEYTRAIN_COLOR_CALIBRATION=0 override is also supported.
#ifndef KEYTRAIN_COLOR_CALIBRATION
#define KEYTRAIN_COLOR_CALIBRATION 1
#endif

namespace FirmwareConfig {
// true: keep BLE available for the entire powered session, including screen-off
// standby. Keep connected links open; advertise again when the phone disconnects.
// false: normal on-demand BLE lifecycle and power-saving disconnects.
// Boot default only: serial `ble permissive on/off` can override until reboot.
// Does not bypass provisioning/binding or disable transit-request deadlines.
constexpr bool BLE_ALWAYS_ON = true;
}

// Apply the saved brightness-80 visual map to normal transit colors.
// Independent of the optional serial calibration tool. Set 0 for raw RGB.
#ifndef KEYTRAIN_COLOR_CORRECTION
#define KEYTRAIN_COLOR_CORRECTION 1
#endif

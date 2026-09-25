#pragma once

namespace FirmwareConfig {
// true: keep BLE available for the entire powered session, including screen-off
// standby. Keep connected links open; advertise again when the phone disconnects.
// false: normal on-demand BLE lifecycle and power-saving disconnects.
// Boot default only: serial `ble permissive on/off` can override until reboot.
// Does not bypass provisioning/binding or disable transit-request deadlines.
constexpr bool BLE_ALWAYS_ON = true;
}

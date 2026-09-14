#pragma once
#include <Arduino.h>

namespace DeviceIdentity {
// Call once during setup, before radio/ADC initialization. Failure is latched
// until reboot: never expose an ID that was not successfully persisted.
bool begin();
String getDeviceId();
constexpr const char* characteristicUUID = "7A1C0003-8F4A-4D2B-9A57-1C2D3E4F5001";
}

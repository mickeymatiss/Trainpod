#include "PerformanceMode.h"
#include "../ble/BleSession.h"
#include <NimBLEDevice.h>
#include <esp32-hal-cpu.h>

static bool displayPerformancePinned=false;
void pinDisplayPerformance() {
  setPerformanceMode(PerformanceMode::ACTIVE);
  displayPerformancePinned=true;
}
bool setPerformanceMode(PerformanceMode mode) {
  if(displayPerformancePinned) return mode==PerformanceMode::ACTIVE;
  // Failed cleanup must not allow downclocking with a live BLE stack.
  if (mode == PerformanceMode::IDLE &&
      (BleSession::anySessionActive() || NimBLEDevice::isInitialized())) return false;
  const uint32_t target = mode == PerformanceMode::ACTIVE ? 160 : 10;
  if (getCpuFrequencyMhz() == target) return true;
  return setCpuFrequencyMhz(target) && getCpuFrequencyMhz() == target;
}

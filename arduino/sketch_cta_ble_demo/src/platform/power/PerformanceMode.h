#pragma once
#include <Arduino.h>
enum class PerformanceMode { IDLE, ACTIVE };
// Arduino loop task only. Request IDLE after synchronous work has finished.
// Never call from BLE callbacks.
bool setPerformanceMode(PerformanceMode mode);

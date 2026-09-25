#pragma once
#include <Arduino.h>
enum class PerformanceMode { IDLE, ACTIVE };
// Pin before starting the renderer: APB changes can wait for a stalled SPI bus.
void pinDisplayPerformance();
// Arduino loop task only.
// Never call from BLE callbacks.
bool setPerformanceMode(PerformanceMode mode);

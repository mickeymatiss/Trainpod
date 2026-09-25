// Trainpod: persistent BLE background color sync is enabled.
// BLE always-on flag: FirmwareConfig.h (true keeps radio available while powered)
// Color settings: pallete.h (visible as an Arduino IDE tab)
// Application: src/products/transit/app/TransitApp.cpp
#include "src/products/transit/app/TransitApp.h"
void setup() { setupTransitApp(); }
void loop() { loopTransitApp(); }

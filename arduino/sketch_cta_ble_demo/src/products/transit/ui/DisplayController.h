#pragma once
#include "RenderSnapshot.h"

// Main-loop facade. Owns transit/selection/timers; never touches TFT hardware.
namespace DisplayController {
#if KEYTRAIN_COLOR_CALIBRATION
void setCalibration(bool enabled,uint32_t rgb=0,uint32_t sequence=0);
uint32_t calibrationShown();
#endif
void begin(); // App state and queues only; no TFT/task startup.
void startRenderer(); // Called once after the first BLE poll.
void setSetupState(int value);
void setPlatforms(const ArrivalBoard& board,uint32_t now);
void nextPlatform(uint32_t now);
void nextStation(uint32_t now);
void setConnected(bool value);
void buttonChanged(bool value,uint32_t now);
bool feedbackHeld();
void themeChanged(uint32_t now);
void suspend(uint32_t now);
void blankStandbyScreen();
void resume(uint32_t now);
void tick(uint32_t now);
uint32_t requestRender(uint64_t transaction=0);
bool command(const char* text);
}

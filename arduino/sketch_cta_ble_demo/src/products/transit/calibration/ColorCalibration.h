#pragma once
#include "../../../../FirmwareConfig.h"
class BacklightFade;
namespace ColorCalibration {
#if KEYTRAIN_COLOR_CALIBRATION
void begin(BacklightFade& backlight);
bool active();
bool command(const char* text);
void tick();
#else
inline void begin(BacklightFade&) {}
inline bool active() { return false; }
inline bool command(const char*) { return false; }
inline void tick() {}
#endif
}

#pragma once
#include <Arduino.h>
#include "PowerLifecycle.h"

// Phone-local clock, advanced by monotonic uptime. No persisted clock at boot.
class NightBrightness {
public:
  static NightBrightness& shared();
  void sync(uint64_t unixMs,int offsetMinutes,uint32_t session);
  uint8_t activeLevel();
  bool command(const char* line);
private:
  int localMinute(); // -1 means unknown/stale; fail dim.
  int day_=PowerConfig::ACTIVE_BRIGHTNESS,night_=50,start_=22,end_=7;
  uint64_t localMs_=0,syncedAt_=0;
  bool known_=false;
  portMUX_TYPE mutex_=portMUX_INITIALIZER_UNLOCKED;
};

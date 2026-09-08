#pragma once
#include <Arduino_GFX_Library.h>
#include "ArrivalDisplay.h"

class ArrivalScreen {
public:
  explicit ArrivalScreen(Arduino_GFX& display) : gfx(display) {}
  void begin(uint32_t now);
  void setPlatforms(const ArrivalBoard& data, uint32_t now);
  void nextPlatform(uint32_t now);
  void setConnected(bool connected);
  void setBatteryPercent(int percent); // -1 means unavailable, never invent a reading.
  void tick(uint32_t now);
  bool hasData() const { return state.hasData; }
private:
  void draw(uint32_t now);
  void text(const std::string& value, int x, int baseline, int width, uint16_t color, bool bold, bool right = false);
  Arduino_GFX& gfx;
  ArrivalScreenState state;
  bool connected = false, dirty = true;
  BatteryState battery = BatteryState::unknown;
  static constexpr int LOW_BATTERY = 20, CAUTION_BATTERY = 50;
};

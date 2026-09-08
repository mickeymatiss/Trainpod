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
  void suspend(uint32_t now);
  void resume(uint32_t now);
  bool hasData() const { return state.hasData; }
private:
  void draw(uint32_t now);
  void text(const std::string& value, int x, int baseline, int width, uint16_t color, uint8_t scale = 1, bool right = false);
  Arduino_GFX& gfx;
  ArrivalScreenState state;
  bool connected = false, dirty = true;
  bool suspended = false;
  uint32_t suspendedAt = 0;
  bool connectionFailed = false, restartConnectionTimer = false;
  uint32_t connectionAttemptStarted = 0;
  static constexpr uint32_t CONNECTION_WARNING_MS = 30000;
  BatteryState battery = BatteryState::unknown;
  static constexpr int LOW_BATTERY = 15, CAUTION_BATTERY = 30;
  static constexpr uint32_t STALE_DISPLAY_MINUTES = 2;
  static constexpr uint32_t STALE_WARNING_MINUTES = 10; // Visual only; does not expire RAM data.
};

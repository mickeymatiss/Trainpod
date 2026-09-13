#pragma once
#include <Arduino_GFX_Library.h>
#include "../data/ArrivalDisplay.h"
#include "animation/EtaFade.h"
#include "animation/PlatformDip.h"
#include <memory>

class ArrivalScreen {
public:
  explicit ArrivalScreen(Arduino_GFX& display) : gfx(display) {}
  void begin(uint32_t now);
  void setPlatforms(const ArrivalBoard& data, uint32_t now);
  void nextPlatform(uint32_t now);
  void nextStation(uint32_t now);
  void setConnected(bool connected);
  void setBatteryPercent(int percent); // -1 means unavailable, never invent a reading.
  void tick(uint32_t now);
  void themeChanged(uint32_t now);
  void suspend(uint32_t now);
  void resume(uint32_t now);
  void setDisplayTransaction(uint64_t tx) { displayTransaction=tx; }
  bool hasData() const { return state.hasData; }
private:
  friend struct ArrivalScreenTest;
  void draw(uint32_t now);
  void drawTheme(uint32_t now);
  bool themeDirty = false;
  void drawFooter(uint32_t now);
  void drawDistanceGauge(const std::string& value, const std::string& unit);
  void drawEta(size_t slot, int value, uint8_t opacity, bool clear);
  void animateEtas(uint32_t now);
  void requestNavigation(bool station, uint32_t now);
  void animatePlatform(uint32_t now);
  void renderPlatformFrame(uint8_t opacity, uint32_t now);
  void copyRegion(int x,int y,int width,int height,uint8_t opacity);
  size_t requestedIndex() const;
  std::string footerKey(uint32_t now) const;
  Arduino_GFX& surface() { return drawingTarget ? *drawingTarget : gfx; }
  Arduino_GFX* drawingTarget=nullptr;
  std::unique_ptr<Arduino_Canvas> navigationCanvas;
  PlatformDip platformDip;
  std::string requestedStation, requestedDirection;
  bool dipStationName=false;
  std::array<bool, 3> retainedCapsules{};
  std::unique_ptr<ArrivalBoard> deferredBoard;
  uint32_t deferredReceived=0;
  uint32_t dipVisibleAge=0;
  bool dipConnected=false,dipConnectionFailed=false;
  BatteryState dipBattery=BatteryState::unknown;
  struct EtaBounds { int16_t x=0, y=0; uint16_t width=0, height=0; };
  std::array<EtaFade, 3> etaFades;
  std::array<EtaBounds, 3> etaBounds;
  PlatformDisplay renderedPlatform;
  size_t renderedPage = 0;
  bool hasRendered = false;
  std::string renderedFooter;
  void text(const std::string& value, int x, int baseline, int width, uint16_t color, uint8_t scale = 1, bool right = false, const GFXfont* font = nullptr);
  uint64_t displayTransaction=0;
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

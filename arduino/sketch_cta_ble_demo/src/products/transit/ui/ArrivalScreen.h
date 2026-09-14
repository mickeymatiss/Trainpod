#pragma once
#include <Arduino_GFX_Library.h>
#include "../data/ArrivalDisplay.h"
#include "animation/EtaFade.h"
#include "animation/PlatformDip.h"
#include "animation/SpringBlock.h"
#include "animation/DisplayEffects.h"
#include "animation/GaugeBezel.h"
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
  void buttonChanged(bool pressed,uint32_t now);
  bool feedbackHeld() const { return springPhysicalHeld || springTestHeld; }
  bool animationNeedsPerformance(uint32_t now) const;
  bool effectsCommand(const char* command, uint32_t now);
  bool springCommand(const char* command,uint32_t now);
  bool transitionCommand(const char* command,uint32_t now);
  void themeChanged(uint32_t now);
  void suspend(uint32_t now);
  void resume(uint32_t now);
  void setDisplayTransaction(uint64_t tx) { displayTransaction=tx; }
  bool hasData() const { return state.hasData; }
private:
  DisplayEffects effects;
  GaugeBezel bezel;
  void drawGaugeBezel(int x,int y,int width,int height,int radius);
  void drawGaugeBezel(int x,int y,int width,int height,int radius,uint16_t baseColor);
  void printEffects(bool help);
  void renderEffectEta(size_t slot,const std::string& value,const GFXfont* font,uint8_t opacity,int bx,int by,int w,int h,int fontPoints);
  std::array<std::array<uint16_t,54*32>,3> etaPixels{};
  std::array<std::array<uint8_t,54*32>,3> etaRimMask{};
  std::array<bool,3> etaRimValid{};
  std::array<std::string,3> etaLoggedValue;
  std::array<int,3> etaLoggedScale{};
  SpringBlock springBlock;
  bool springPhysicalHeld=false,springTestHeld=false;
  SpringBlock::State springLoggedState=SpringBlock::State::Retracted;
  void logSpringState();
  std::unique_ptr<Arduino_Canvas> springCanvas;
  std::array<uint16_t,76*22> springBackdrop{};
  bool springVisible=false, springInvalidated=false;
  uint32_t springLastFrame=0;
  int springPaintedPosition=-1;
  void drawSpring(uint32_t now);
  void clearSpring();
  friend struct ArrivalScreenTest;
  void draw(uint32_t now);
  void drawIncrementalFrame(uint32_t now);
  void drawInstrumentShell();
  void drawRowShell(size_t slot);
  void drawLineWindow(size_t slot,const ArrivalDisplay* arrival);
  uint16_t neutralLineColor() const;
  void drawTheme(uint32_t now);
  bool themeDirty = false;
  void drawFooter(uint32_t now);
  void drawScreenLip(bool footerOnly=false);
  void drawDistanceGauge(const std::string& value, const std::string& unit);
  void drawEta(size_t slot, int value, uint8_t opacity, bool clear);
  void animateEtas(uint32_t now);
  enum class ContentUpdate { InitialShell, DataRefresh, Replacement };
  ContentUpdate contentUpdateKind() const;
  void updateEtaContent(size_t slot,int next,ContentUpdate kind,uint32_t now);
  std::array<bool,3> etaContentRepaint{};
  void requestNavigation(bool station, uint32_t now);
  void animatePlatform(uint32_t now);
  void beginNavigationTransition(uint32_t now);
  void renderPlatformFrame(uint32_t now);
  void copyRegion(int x,int y,int width,int height);
  std::string footerKey(uint32_t now) const;
  std::string footerStatusKey(uint32_t now) const;
  Arduino_GFX& surface() { return drawingTarget ? *drawingTarget : gfx; }
  Arduino_GFX* drawingTarget=nullptr;
  std::unique_ptr<Arduino_Canvas> navigationCanvas;
  PlatformDip platformDip;
  std::array<PlatformDisplay,5> transitionSource,transitionShown;
  std::array<size_t,5> transitionSourcePage{},transitionShownPage{};
  std::array<int,5> transitionPaintedOpacity{{-1,-1,-1,-1,-1}};
  std::array<bool,5> transitionPaintedIncoming{};
  std::array<uint8_t,5> transitionFields{};
  // Reusable neutral-shell strip, not another full-screen framebuffer.
  std::array<uint16_t,320*32> transitionShell{};
  struct EtaBounds { int16_t x=0, y=0; uint16_t width=0, height=0; };
  std::array<EtaFade, 3> etaFades;
  std::array<EtaBounds, 3> etaBounds;
  PlatformDisplay renderedPlatform;
  size_t renderedPage = 0;
  bool hasRendered = false;
  std::string renderedFooter;
  std::string renderedFooterStatus;
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

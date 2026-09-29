#pragma once
#include <Arduino_GFX_Library.h>
#include "../data/ArrivalDisplay.h"
#include "animation/EtaFade.h"
#include "animation/PlatformDip.h"
#include "animation/SpringBlock.h"
#include "animation/DisplayEffects.h"
#include "animation/GaugeBezel.h"
#include <memory>
#include "RenderSnapshot.h"

class ArrivalScreen {
public:
  explicit ArrivalScreen(Arduino_GFX& display) : gfx(display) {}
  void applySnapshot(const RenderSnapshot& snapshot,uint32_t now);
  bool pending() const;
  const char* error() const { return renderError; }
  void invalidate();
  void setConnected(bool connected);
  void setBatteryPercent(int percent); // -1 means unavailable, never invent a reading.
  void tick(uint32_t now);
  void buttonChanged(bool pressed,uint32_t now);
  bool feedbackHeld() const { return springPhysicalHeld || springTestHeld; }
  bool effectsCommand(const char* command, uint32_t now);
  bool springCommand(const char* command,uint32_t now);
  bool transitionCommand(const char* command,uint32_t now);
  void themeChanged(uint32_t now);
  bool hasData() const { return state.hasData; }
private:
  DisplayEffects effects;
  GaugeBezel bezel;
  void drawGaugeBezel(int x,int y,int width,int height,int radius);
  void drawGaugeBezel(int x,int y,int width,int height,int radius,uint16_t baseColor);
  void printEffects(bool help);
  void renderEffectEta(size_t slot,const std::string& value,const GFXfont* font,uint8_t opacity,int bx,int by,int w,int h,int fontPoints);
  void presentEta(size_t slot,uint8_t opacity);
  // Single-worker renderer: one reusable glyph scratch mask for all cells.
  std::array<uint8_t,54*32> etaInk{};
  std::array<std::array<uint16_t,54*32>,6> etaPixels{};
  // Full-strength images; opacity is deliberately not part of the cache key.
  // Theme, effects and layout changes invalidate etaRimValid and these images.
  std::array<int,6> etaCachedValue{};
  std::array<uint16_t,50*28> etaFrame{};
  std::array<std::array<uint8_t,54*32>,6> etaRimMask{};
  std::array<bool,6> etaRimValid{};
  std::array<std::string,6> etaLoggedValue;
  std::array<int,6> etaLoggedScale{};
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
  // Both layouts retain the same three vertical rows and 54 x 32 ETA gauges.
  size_t visibleSlots() const { return state.arrivalsPerPage(); }
  size_t footerGroup() const { return visibleSlots()+1; }
  int cellX(size_t slot) const { return 8+(state.compact ? int(slot%2)*(gfx.width()/2) : 0); }
  int cellY(size_t slot) const { return 37+int(state.compact ? slot/2 : slot)*((gfx.height()-52)/3); }
  int cellRight(size_t slot) const { return state.compact ? cellX(slot)+gfx.width()/2-16 : gfx.width()-8; }
  static constexpr int routeSize=28;
  int lineX(size_t slot) const { return cellX(slot)+(state.compact ? 59 : 63); }
  int lineY(size_t slot) const { return cellY(slot)+(32-routeSize)/2; }
  int nameX(size_t slot) const { return cellX(slot)+(state.compact ? 94 : 100); }
  int nameWidth(size_t slot) const { return state.compact ? cellRight(slot)-nameX(slot) : 60; }
  int nameRegionWidth(size_t slot) const { return state.compact ? nameWidth(slot) : 63; }
  int routeRegionWidth(size_t slot) const { return nameX(slot)+nameRegionWidth(slot)-(lineX(slot)-2); }
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
  std::array<bool,6> etaContentRepaint{};
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
  std::array<PlatformDisplay,8> transitionSource,transitionShown;
  std::array<size_t,8> transitionSourcePage{},transitionShownPage{};
  std::array<int,8> transitionPaintedOpacity{};
  std::array<bool,8> transitionPaintedIncoming{};
  std::array<uint8_t,8> transitionFields{};
  int transitionPaintedLights=-1;
  int transitionPaintedNames=-1,transitionPaintedDestinations=-1;
  // Reusable neutral-shell strip, not another full-screen framebuffer.
  std::array<uint16_t,320*32> transitionShell{};
  struct EtaBounds { int16_t x=0, y=0; uint16_t width=0, height=0; };
  std::array<EtaFade, 6> etaFades;
  std::array<EtaBounds, 6> etaBounds;
  PlatformDisplay renderedPlatform;
  size_t renderedPage = 0;
  bool hasRendered = false;
  std::string renderedFooter;
  std::string renderedFooterStatus;
  void text(const std::string& value, int x, int baseline, int width, uint16_t color, uint8_t scale = 1, bool right = false, const GFXfont* font = nullptr);
  Arduino_GFX& gfx;
  ArrivalScreenState state;
  const char* renderError=nullptr;
  uint32_t styleRevision=UINT32_MAX;
  bool connected = false, dirty = true;
  bool suspended = false;
  bool connectionFailed = false, restartConnectionTimer = false;
  uint32_t connectionAttemptStarted = 0;
  static constexpr uint32_t CONNECTION_WARNING_MS = 30000;
  BatteryState battery = BatteryState::unknown;
  static constexpr int LOW_BATTERY = 15, CAUTION_BATTERY = 30;
  static constexpr uint32_t STALE_DISPLAY_MINUTES = 2;
  static constexpr uint32_t STALE_WARNING_MINUTES = 10; // Visual only; does not expire RAM data.
};

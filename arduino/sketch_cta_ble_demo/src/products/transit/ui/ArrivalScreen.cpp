#include "ArrivalScreen.h"
#include <cstdlib>
#include "theme/pallete.h"
#ifndef TRAINPOD_RENDER_TEST
#include "../../../platform/diagnostics/DiagnosticStore.h"
#include "../../../platform/metrics/MetricsStore.h"
#include <esp_timer.h>
#include "../../../platform/power/PerformanceMode.h"
#endif
#include "fonts/DepartureMono11.h"
#include "fonts/BarlowCondensedRegular12.h"
#include "fonts/BarlowCondensedRegular16.h"
#include "fonts/BarlowCondensedRegular20.h"
#include "fonts/BarlowCondensedRegular24.h"
#include "fonts/BarlowCondensedSemiBold24.h"
#include "fonts/ArrivalSans12.h"
#include "fonts/ArrivalSans10.h"
#include "fonts/ArrivalSans8.h"
#include "fonts/ArrivalItalic18.h"
#include "fonts/ArrivalItalic12.h"
#include "fonts/ArrivalItalic9.h"

namespace {
uint16_t etaColor(uint8_t opacity) { return pallete::arrivalBadgeText(opacity); }
std::string routeAbbreviation(const std::string& label) {
  if (label == "Green" || label == "GRN") return "GRN";
  if (label == "Blue" || label == "BLU") return "BLU";
  if (label == "Pink" || label == "PNK") return "PNK";
  if (label == "Red" || label == "RED") return "RED";
  if (label == "Orange" || label == "Orng" || label == "ORG") return "ORG";
  if (label == "Grey" || label == "Gray" || label == "GRY") return "GRY";
  if (label == "Brown") return "BRN";
  if (label == "Purple") return "PUR";
  if (label == "Yellow") return "YLW";
  return label.substr(0, 3);
}

}

void ArrivalScreen::begin(uint32_t now) { state.clockAdvanced = now; connectionAttemptStarted = now; draw(now); }
std::string ArrivalScreen::footerKey(uint32_t now) const {
  const uint32_t age=state.hasData && state.ageMinutes(now)>=STALE_DISPLAY_MINUTES ? state.ageMinutes(now) : 0;
  return std::to_string(connected)+":"+std::to_string(connectionFailed)+":"+
    std::to_string(int(battery))+":"+std::to_string(age)+":"+state.current().distanceValue+":"+state.current().distanceUnit+":"+
    std::to_string(state.platform)+":"+std::to_string(state.data.platformCount);
}

size_t ArrivalScreen::requestedIndex() const {
  for(size_t i=0;i<state.data.platformCount;++i)
    if(state.data.platforms[i].stationName==requestedStation && state.data.platforms[i].direction==requestedDirection) return i;
  return 0;
}

void ArrivalScreen::requestNavigation(bool station,uint32_t now) {
  if(!state.hasData || suspended) return;
  ArrivalScreenState selection=state;
  if(platformDip.active) selection.platform=requestedIndex();
  if(station) selection.nextStation(now); else selection.nextPlatform(now);
  const auto& wanted=selection.current();
  if(!platformDip.active && selection.platform==state.platform) return;
  if(!navigationCanvas) {
    navigationCanvas.reset(new Arduino_Canvas(gfx.width(),gfx.height(),nullptr));
    if(!navigationCanvas->begin()) {
      navigationCanvas.reset(); Serial.println("[UI] Platform transition buffer unavailable"); return;
    }
  }
  requestedStation=wanted.stationName;requestedDirection=wanted.direction;
  for(size_t slot=0;slot<3;++slot)
    retainedCapsules[slot]=state.page*3+slot<state.current().arrivalCount &&
      selection.page*3+slot<wanted.arrivalCount;
  dipStationName=dipStationName || requestedStation!=state.current().stationName;
  if(platformDip.active) { platformDip.retarget(now);return; }
  dipStationName=requestedStation!=state.current().stationName;
  dipConnected=connected;dipConnectionFailed=connectionFailed;dipBattery=battery;
  dipVisibleAge=state.ageMinutes(now)>=STALE_DISPLAY_MINUTES ? state.ageMinutes(now) : 0;
  platformDip.begin(now);
}

void ArrivalScreen::copyRegion(int x,int y,int width,int height,uint8_t opacity) {
  auto* pixels=navigationCanvas->getFramebuffer();
  const int stride=gfx.width();
  for(int row=y;row<y+height;++row) {
    auto* line=pixels+row*stride+x;
    bool stableCapsuleRow=false;
    for(size_t slot=0;slot<3;++slot) {
      const int top=37+int(slot)*((gfx.height()-52)/3);
      if(retainedCapsules[slot] && row>=top && row<top+32) stableCapsuleRow=true;
    }
    for(int col=0;col<width;++col) {
      const uint16_t color=line[col];
      // Shared cutouts stay at their original color. Only their digits dip
      // toward the cutout background; rounded-corner paper pixels stay paper.
      const uint16_t background=stableCapsuleRow && x+col>=8 && x+col<62 && color!=pallete::background() ? pallete::arrivalBadge() : pallete::background();
      const int r=(((color>>11)&31)*opacity+((background>>11)&31)*(255-opacity)+127)/255;
      const int g=(((color>>5)&63)*opacity+((background>>5)&63)*(255-opacity)+127)/255;
      const int b=((color&31)*opacity+(background&31)*(255-opacity)+127)/255;
      line[col]=(r<<11)|(g<<5)|b;
    }
  }
  // Only fully composed pixels go to the TFT: no intermediate clear operation.
  if(x==0 && width==stride) gfx.draw16bitRGBBitmap(x,y,pixels+y*stride,width,height);
  else for(int row=y;row<y+height;++row)
    gfx.draw16bitRGBBitmap(x,row,pixels+row*stride+x,width,1);
}

void ArrivalScreen::renderPlatformFrame(uint8_t opacity,uint32_t now) {
  drawingTarget=navigationCanvas.get();
  const auto& platform=state.current();
  const int width=surface().width(),rowHeight=(surface().height()-52)/3;
  surface().fillScreen(pallete::background()); // RAM only, never a visible background frame.
  text(platform.direction,width-103,23,85,pallete::secondaryText(),1,true,&FreeSans12pt7b);
  if(dipStationName) text(platform.stationName,18,23,width-129,pallete::primaryText(),1,false,&BarlowCondensedSemiBold24);
  for(size_t slot=0;slot<3;++slot) {
    const size_t index=state.page*3+slot;
    if(index>=platform.arrivalCount) continue;
    const auto& arrival=platform.arrivals[index];
    const int baseline=60+int(slot)*rowHeight;
    surface().fillRoundRect(8,baseline-23,54,32,10,pallete::arrivalBadge());
    // During navigation, all numbers use the common dip rather than individual fades.
    drawEta(slot,arrival.eta,255,false);
    surface().fillRoundRect(72,baseline-18,22,22,4,pallete::routeColor(arrival));
    text(routeAbbreviation(arrival.routeLabel),102,baseline+2,60,pallete::primaryText(),1,false,&BarlowCondensedSemiBold24);
    text(arrival.destination,181,baseline+1,width-181-8,pallete::secondaryText(),1,true,&ArrivalSans10);
  }
  if (platform.direction == "MTA" && platform.arrivalCount == 0)
    text("No upcoming trains",18,70,width-36,pallete::secondaryText(),1,false,&ArrivalSans10);
  drawFooter(now); // Only distance will be copied.
  drawingTarget=nullptr;
  copyRegion(width-104,0,96,30,opacity);
  if(dipStationName) copyRegion(8,0,width-119,30,opacity);
  copyRegion(0,34,width,116,opacity);
  copyRegion((width-120)/2,150,120,22,opacity);
}

void ArrivalScreen::animatePlatform(uint32_t now) {
  if(!setPerformanceMode(PerformanceMode::ACTIVE) || !platformDip.tick(now)) return;
  if(platformDip.swaps()) {
    if(deferredBoard) { state.setBoard(*deferredBoard,deferredReceived);deferredBoard.reset(); }
    state.platform=requestedIndex();state.page=0;state.pageStarted=now;
  }
  renderPlatformFrame(platformDip.opacity(),now);
  if(!platformDip.active) {
    renderedPlatform=state.current();renderedPage=state.page;hasRendered=true;
    for(size_t slot=0;slot<3;++slot) {
      const size_t index=state.page*3+slot;
      etaFades[slot].reset(index<state.current().arrivalCount ? state.current().arrivals[index].eta : 0);
    }
    const uint32_t age=state.ageMinutes(now)>=STALE_DISPLAY_MINUTES ? state.ageMinutes(now) : 0;
    if(dipConnected==connected && dipConnectionFailed==connectionFailed && dipBattery==battery && dipVisibleAge==age)
      renderedFooter=footerKey(now);
    dirty=true;
    if(deferredBoard) { state.setBoard(*deferredBoard,deferredReceived);deferredBoard.reset(); }
    Serial.printf("[UI] Platform %u/%u: %s / %s\n",unsigned(state.platform+1),unsigned(state.data.platformCount),
      state.current().stationName.c_str(),state.current().direction.c_str());
  }
}
void ArrivalScreen::setPlatforms(const ArrivalBoard& data, uint32_t now) {
  if (platformDip.active) {
    deferredBoard.reset(new ArrivalBoard(data)); deferredReceived=now; return;
  }
  state.setBoard(data, now); dirty=true;
}
void ArrivalScreen::nextPlatform(uint32_t now) { requestNavigation(false,now); }
void ArrivalScreen::nextStation(uint32_t now) { requestNavigation(true,now); }
void ArrivalScreen::setConnected(bool value) {
  if (connected == value) return;
  connected = value;
  connectionFailed = false;
  restartConnectionTimer = !value;
  dirty = true;
}
void ArrivalScreen::setBatteryPercent(int percent) {
  const auto value = percent < 0 ? BatteryState::unknown : percent < LOW_BATTERY ? BatteryState::low : percent <= CAUTION_BATTERY ? BatteryState::caution : BatteryState::healthy;
  if (battery != value) { battery = value; dirty = true; }
}
void ArrivalScreen::tick(uint32_t now) {
  if (suspended) return;
  if (themeDirty) { drawTheme(now); if (themeDirty) return; }
  if (restartConnectionTimer) { connectionAttemptStarted = now; restartConnectionTimer = false; }
  const bool failed = !connected && uint32_t(now - connectionAttemptStarted) >= CONNECTION_WARNING_MS;
  if (connectionFailed != failed) { connectionFailed = failed; dirty = true; }
  if (platformDip.active) { animatePlatform(now); return; }
  if (state.tick(now)) dirty = true;
  if (dirty) draw(now);
  animateEtas(now);
}

void ArrivalScreen::suspend(uint32_t now) {
  if (suspended) return;
  suspended = true;
  suspendedAt = now;
}

void ArrivalScreen::resume(uint32_t now) {
  if (!suspended) return;
  const uint32_t elapsed = now - suspendedAt;
  // Freeze pagination and animation, not train freshness or BLE readiness age.
  state.pageStarted += elapsed;
  state.clockAdvanced += elapsed;
  suspended = false;
  dirty = true;
  tick(now); // Show the saved platform/page immediately, without waiting for data.
}

void ArrivalScreen::text(const std::string& value, int x, int baseline, int width, uint16_t color, uint8_t scale, bool right, const GFXfont* font) {
  // Every label glyph uses Barlow, including digits in station names.
  // Explicit ETA/distance numeral fonts pass through unchanged.
  const GFXfont* labelFont = !font ? &BarlowCondensedRegular12
    : font == &FreeSans12pt7b ? &BarlowCondensedRegular24
    : font == &ArrivalSans10 ? &BarlowCondensedRegular20
    : font == &ArrivalSans8 ? &BarlowCondensedRegular16 : font;
  surface().setFont(labelFont);
  surface().setTextSize(scale); surface().setTextWrap(false); surface().setTextColor(color);
  // The bundled font is ASCII. Transliteration happens in the iOS adapter.
  String fitted(value.c_str());
  int16_t bx, by; uint16_t w, h;
  surface().getTextBounds(fitted, 0, baseline, &bx, &by, &w, &h);
  if (w > width) {
    while (fitted.length()) {
      fitted.remove(fitted.length() - 1);
      surface().getTextBounds(fitted + "...", 0, baseline, &bx, &by, &w, &h);
      if (w <= width) break;
    }
    fitted += "...";
  }
  surface().getTextBounds(fitted, 0, baseline, &bx, &by, &w, &h);
  surface().setCursor((right ? x + width - w : x) - bx, baseline);
  surface().print(fitted);
}

void ArrivalScreen::drawEta(size_t slot, int value, uint8_t opacity, bool clear) {
  auto& bounds = etaBounds[slot];
  if (clear && bounds.width && bounds.height)
    surface().fillRect(bounds.x, bounds.y, bounds.width, bounds.height, pallete::arrivalBadge());
  const std::string eta = std::to_string(value);
  const int capsuleY = 37 + int(slot) * ((surface().height()-52)/3);
  surface().setTextWrap(false);
  surface().setTextSize(1);
  surface().setTextColor(etaColor(opacity));
  int16_t bx, by; uint16_t w, h;
  // Native-size bold italic glyphs; keep generous padding inside the capsule.
  for (const GFXfont* font : {&FreeSansBoldOblique18pt7b, &FreeSansBoldOblique12pt7b, &FreeSansBoldOblique9pt7b}) {
    surface().setFont(font);
    surface().getTextBounds(eta.c_str(), 0, 0, &bx, &by, &w, &h);
    if (w <= 44 && h <= 26) break;
  }
  bounds = {int16_t(8 + (54-int(w))/2), int16_t(capsuleY + (32-int(h))/2), w, h};
  surface().setCursor(bounds.x-bx, bounds.y-by);
  surface().print(eta.c_str());
}

void ArrivalScreen::animateEtas(uint32_t now) {
  bool active=false;
  for (const auto& fade:etaFades) active=active || fade.active;
  if (!hasRendered || !active || !setPerformanceMode(PerformanceMode::ACTIVE)) return;
  for (size_t slot=0; slot<3; ++slot)
    if (etaFades[slot].tick(now))
      drawEta(slot, etaFades[slot].value, etaFades[slot].opacity, true);
}

void ArrivalScreen::drawFooter(uint32_t now) {
  const int width=surface().width(), height=surface().height(), padding=8, footer=height-12;
  const auto& platform=state.current();
  surface().fillRect(0, height-22, width, 22, pallete::background());
  // Contextual footer: healthy BLE, fresh data and healthy/unknown battery are silent.
  int statusX = padding;
  if (!connected && !connectionFailed) {
    surface().fillCircle(statusX + 3, footer, 2, pallete::secondaryText());
    statusX += 14;
  }
  if (battery == BatteryState::caution || battery == BatteryState::low) {
    const uint16_t color = battery == BatteryState::low ? pallete::primaryText() : pallete::secondaryText();
    surface().drawRect(statusX, footer - 4, 12, 8, color);
    surface().drawFastVLine(statusX + 12, footer - 2, 4, color);
    surface().fillRect(statusX + 2, footer - 2, battery == BatteryState::low ? 2 : 5, 4, color);
    statusX += 22;
  }
  const uint32_t age = state.ageMinutes(now);
  if (state.hasData && age >= STALE_DISPLAY_MINUTES) {
    const bool warning = age >= STALE_WARNING_MINUTES;
    text(std::to_string(age) + "m old" + (warning ? "!" : ""), statusX, footer + 4,
      std::max(0, (platform.distanceValue.empty() ? width-padding : (width-120)/2-8) - statusX), warning ? pallete::primaryText() : pallete::secondaryText());
  }
  if (!platform.distanceValue.empty()) drawDistanceGauge(platform.distanceValue, platform.distanceUnit);

}

void ArrivalScreen::draw(uint32_t now) {
  const uint64_t renderStarted=esp_timer_get_time();
  DiagnosticStore::shared().event(EventCode::DISPLAY_UPDATE_START,LogLevel::Info,state.hasData);
  if (!setPerformanceMode(PerformanceMode::ACTIVE)) return;
  dirty = false;
  const int width=surface().width(), height=surface().height(), padding=8;
  const auto& platform=state.current();
  const bool full = !hasRendered || renderedPage != state.page ||
    renderedPlatform.stationName != platform.stationName ||
    renderedPlatform.direction != platform.direction ||
    (platform.direction == "MTA" && (renderedPlatform.arrivalCount == 0) != (platform.arrivalCount == 0));
  if (full) {
    surface().fillScreen(pallete::background());
    text(platform.direction, width-103, 23, 85, pallete::secondaryText(), 1, true, &FreeSans12pt7b);
    text(platform.stationName, padding+10, 23, width-129, pallete::primaryText(), 1, false, &BarlowCondensedSemiBold24);
    surface().drawFastHLine(padding,31,width-padding*2,pallete::detail());
    if (state.hasData) Serial.printf("[UI] Platform %u/%u: %s / %s\n",
      unsigned(state.platform+1),unsigned(state.data.platformCount),
      platform.stationName.c_str(),platform.direction.c_str());
  }
  if (platform.direction == "MTA" && platform.arrivalCount == 0)
    text("No upcoming trains",18,70,width-36,pallete::secondaryText(),1,false,&ArrivalSans10);
  const int rowHeight=(height-52)/3;
  for (size_t slot=0;slot<3;++slot) {
    const size_t index=state.page*3+slot;
    const bool present=index<platform.arrivalCount;
    const bool wasPresent=hasRendered && renderedPage*3+slot<renderedPlatform.arrivalCount;
    const int baseline=60+int(slot)*rowHeight;
    if (!present) {
      etaFades[slot].reset(0);
      if (!full && wasPresent) surface().fillRect(0,baseline-23,width,32,pallete::background());
      etaBounds[slot]={};
      continue;
    }
    const auto& arrival=platform.arrivals[index];
    if (full || !wasPresent) {
      surface().fillRoundRect(padding,baseline-23,54,32,10,pallete::arrivalBadge());
      etaFades[slot].reset(arrival.eta);
      drawEta(slot,arrival.eta,255,false);
    } else etaFades[slot].request(arrival.eta,now);

    // Compare nonnumeric cells independently; ETA frames never enter this path.
    const auto& old=renderedPlatform.arrivals[wasPresent ? renderedPage*3+slot : 0];
    if (full || !wasPresent || old.routeLabel != arrival.routeLabel || old.routeColor != arrival.routeColor) {
      if (!full) surface().fillRect(70,baseline-23,95,32,pallete::background());
      surface().fillRoundRect(72,baseline-18,22,22,4,pallete::routeColor(arrival));
      text(routeAbbreviation(arrival.routeLabel),102,baseline+2,60,pallete::primaryText(),1,false,&BarlowCondensedSemiBold24);
    }
    if (full || !wasPresent || old.destination != arrival.destination) {
      if (!full) surface().fillRect(181,baseline-23,width-181,32,pallete::background());
      text(arrival.destination,181,baseline+1,width-181-padding,pallete::secondaryText(),1,true,&ArrivalSans10);
    }
  }
  const auto key=footerKey(now);
  if (full || key != renderedFooter) { drawFooter(now); renderedFooter=key; }
  renderedPlatform=platform; renderedPage=state.page; hasRendered=true;
  DiagnosticStore::shared().event(EventCode::DISPLAY_UPDATE_COMPLETE,LogLevel::Info,state.hasData);
  if (displayTransaction) {
    DiagnosticStore::shared().event(EventCode::DISPLAY_UPDATED,LogLevel::Info,
      int32_t((esp_timer_get_time()-renderStarted)/1000),0,displayTransaction);
    displayTransaction=0;
  }
  if (state.hasData) {
    DiagnosticStore::shared().startupComplete();
    const uint64_t latencyMs = esp_timer_get_time()/1000;
    MetricsStore::shared().recordBootToData(latencyMs > UINT32_MAX ? UINT32_MAX : uint32_t(latencyMs));
  }
}

void ArrivalScreen::themeChanged(uint32_t now) {
  hasRendered = false;
  dirty = true;
  themeDirty = true;
  if (!suspended) drawTheme(now);
}

void ArrivalScreen::drawTheme(uint32_t now) {
  if (!navigationCanvas) {
    navigationCanvas.reset(new Arduino_Canvas(gfx.width(), gfx.height(), nullptr));
    if (!navigationCanvas->begin()) navigationCanvas.reset();
  }
  if (!navigationCanvas) return; // Keep dirty; retry without visibly clearing the panel.
  drawingTarget = navigationCanvas.get();
  draw(now);
  drawingTarget = nullptr;
  if (dirty) return; // Performance transition deferred the render.
  gfx.draw16bitRGBBitmap(0, 0, navigationCanvas->getFramebuffer(), gfx.width(), gfx.height());
  themeDirty = false;
}

// Compact distance tab, with the same bold-italic numeral family as arrivals.
void ArrivalScreen::drawDistanceGauge(const std::string& value, const std::string& unit) {
  // Enforce display rounding even when an older phone sends exact feet.
  const std::string displayValue = unit == "ft"
    ? std::to_string(((std::strtoul(value.c_str(), nullptr, 10) + 50) / 100) * 100)
    : value;
  const int width=surface().width(), height=surface().height();
  const int tabWidth=87, tabHeight=22, cornerRadius=6;
  surface().fillRoundRect((width-tabWidth)/2,height-tabHeight,tabWidth,
                          tabHeight+cornerRadius,cornerRadius,pallete::arrivalBadge());
  const int gap=4, maxWidth=71, baseline=height-4;
  surface().setTextSize(1); surface().setTextWrap(false);
  surface().setFont(&BarlowCondensedRegular16);
  int16_t bx,by; uint16_t unitWidth,unitHeight,numberWidth,numberHeight;
  surface().getTextBounds(unit.c_str(),0,0,&bx,&by,&unitWidth,&unitHeight);
  const GFXfont* numberFont = &FreeSansBoldOblique12pt7b;
  surface().setFont(numberFont);
  surface().getTextBounds(displayValue.c_str(),0,0,&bx,&by,&numberWidth,&numberHeight);
  if (numberWidth > maxWidth-int(unitWidth)-gap || numberHeight > 18) {
    numberFont = &FreeSansBoldOblique9pt7b;
    surface().setFont(numberFont);
    surface().getTextBounds(displayValue.c_str(),0,0,&bx,&by,&numberWidth,&numberHeight);
  }
  const int fittedWidth=std::min(int(numberWidth),maxWidth-int(unitWidth)-gap);
  const int startX=(width-fittedWidth-gap-int(unitWidth))/2;
  text(displayValue,startX,baseline,fittedWidth,pallete::arrivalBadgeText(255),1,false,numberFont);
  text(unit,startX+fittedWidth+gap,baseline,unitWidth,pallete::arrivalBadgeText(255),1,false,&ArrivalSans8);
}

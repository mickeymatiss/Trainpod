#include "../../../platform/diagnostics/SerialLog.h"
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
#include "fonts/BarlowCondensedSemiBold22.h"
#include "fonts/BarlowCondensedSemiBold28.h"
#include "fonts/BarlowCondensedRegular23.h"
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
  return footerStatusKey(now)+":"+state.current().distanceValue+":"+state.current().distanceUnit;
}
std::string ArrivalScreen::footerStatusKey(uint32_t now) const {
  const uint32_t age=state.hasData && state.ageMinutes(now)>=STALE_DISPLAY_MINUTES ? state.ageMinutes(now) : 0;
  return std::to_string(connected)+":"+std::to_string(connectionFailed)+":"+
    std::to_string(int(battery))+":"+std::to_string(age);
}

void ArrivalScreen::requestNavigation(bool station,uint32_t now) {
  if(!state.hasData || suspended) return;
  ArrivalScreenState selection=state;
  if(station) selection.nextStation(now); else selection.nextPlatform(now);
  if(selection.platform==state.platform && selection.page==state.page) return;
  beginNavigationTransition(now);
  state.platform=selection.platform;state.page=selection.page;state.pageStarted=now;
  dirty=true;
}

void ArrivalScreen::beginNavigationTransition(uint32_t now) {
  if(!hasRendered || !navigationCanvas) return;
  transitionPaintedOpacity.fill(-1);
  for(size_t group=0;group<5;++group) {
    if(!platformDip.active || platformDip.groups[group].opacity==255) transitionFields[group]=0;
    transitionSource[group]=platformDip.active ? transitionShown[group] : renderedPlatform;
    transitionSourcePage[group]=platformDip.active ? transitionShownPage[group] : renderedPage;
    if(!platformDip.active && group>=1 && group<=3) {
      const size_t slot=group-1,index=renderedPage*3+slot;
      if(index<transitionSource[group].arrivalCount)
        transitionSource[group].arrivals[index].eta=etaFades[slot].value;
    }
    transitionShown[group]=transitionSource[group];
    transitionShownPage[group]=transitionSourcePage[group];
  }
  if(platformDip.active) platformDip.retarget(now); else platformDip.begin(now);
}

void ArrivalScreen::copyRegion(int x,int y,int width,int height) {
  auto* pixels=navigationCanvas->getFramebuffer();
  const int stride=gfx.width();
  // RAM composition is complete; never expose intermediate clears.
  if(x==0 && width==stride) gfx.draw16bitRGBBitmap(x,y,pixels+y*stride,width,height);
  else for(int row=y;row<y+height;++row)
    gfx.draw16bitRGBBitmap(x,row,pixels+row*stride+x,width,1);
}

void ArrivalScreen::renderPlatformFrame(uint32_t now) {
  drawingTarget=navigationCanvas.get();
  const int width=gfx.width(),rowHeight=(gfx.height()-52)/3;
  auto* pixels=navigationCanvas->getFramebuffer();
  const ArrivalDisplay empty{"",0,"",-1};
  for(size_t group=0;group<5;++group) {
    const auto& phase=platformDip.groups[group];
    const auto& source=transitionSource[group];
    const auto& target=state.current();
    auto& fields=transitionFields[group];
    // Latch changed fields until completion, including partially faded fields
    // carried across a retarget. Equal fields are never sent to the display.
    if(group==0) {
      if(source.stationName!=target.stationName) fields|=1;
      if(source.direction!=target.direction) fields|=2;
    } else if(group==4) {
      if(source.distanceValue!=target.distanceValue || source.distanceUnit!=target.distanceUnit) fields|=1;
    } else {
      const size_t slot=group-1,oldIndex=transitionSourcePage[group]*3+slot,newIndex=state.page*3+slot;
      const auto& a=oldIndex<source.arrivalCount ? source.arrivals[oldIndex] : empty;
      const auto& b=newIndex<target.arrivalCount ? target.arrivals[newIndex] : empty;
      if(a.eta!=b.eta) fields|=1;
      if(a.routeLabel.empty()!=b.routeLabel.empty() ||
          (!a.routeLabel.empty() && !b.routeLabel.empty() && a.routeColor!=b.routeColor)) fields|=2;
      if(routeAbbreviation(a.routeLabel)!=routeAbbreviation(b.routeLabel)) fields|=4;
      if(a.destination!=b.destination) fields|=8;
    }
    if(!fields || (transitionPaintedOpacity[group]==phase.opacity &&
        transitionPaintedIncoming[group]==phase.incoming)) continue;
    const auto& platform=phase.incoming ? target : source;
    const size_t page=phase.incoming ? state.page : transitionSourcePage[group];
    const int x=group==4 ? (width-87)/2 : 8;
    const int y=group==0 ? 1 : group==4 ? gfx.height()-22 : 37+int(group-1)*rowHeight;
    const int w=group==4 ? 87 : width-16;
    const int h=group==0 ? 29 : group==4 ? 22 : 32;
    surface().fillRect(x,y,w,h,pallete::background()); // scratch RAM only
    if(group>=1 && group<=3) {
      drawRowShell(group-1);
      if(fields&4) for(int dot : {116,121,126})
        surface().fillCircle(dot,y+18,1,pallete::secondaryText());
    }
    if(group==4) drawDistanceGauge("","");
    for(int row=0;row<h;++row)
      std::copy_n(pixels+(y+row)*width+x,w,transitionShell.data()+row*w);
    if(group==0) {
      if(fields&2) text(platform.direction,width-103,23,85,pallete::secondaryText(),1,true,&FreeSans12pt7b);
      if(fields&1) text(platform.stationName,18,23,width-129,pallete::primaryText(),1,false,&BarlowCondensedSemiBold28);
    } else if(group==4) {
      drawDistanceGauge(platform.distanceValue,platform.distanceUnit);
    } else {
      const size_t slot=group-1,index=page*3+slot;
      const auto& arrival=index<platform.arrivalCount ? platform.arrivals[index] : empty;
      const int baseline=60+int(slot)*rowHeight;
      if(fields&1) drawEta(slot,arrival.eta,255,false);
      if(fields&2) drawLineWindow(slot,index<platform.arrivalCount ? &arrival : nullptr);
      if((fields&4) && !arrival.routeLabel.empty()) {
        surface().fillRect(102,y,63,32,pallete::background());
        text(routeAbbreviation(arrival.routeLabel),102,baseline+2,60,pallete::primaryText(),1,false,&BarlowCondensedSemiBold22);
      }
      if(fields&8) text(arrival.destination,181,baseline+1,width-189,pallete::secondaryText(),1,true,&BarlowCondensedRegular23);
    }
    const auto dynamicPixel=[&](int px,int py) {
      if(group==0) return ((fields&1) && px>=18 && px<209) || ((fields&2) && px>=width-103 && px<width-18);
      if(group==4) return GaugeBezel::inside(px-x,py-y,87,28,6) &&
        !(bezel.distance && bezel.rim(px-x,py-y,87,28,6,(uint32_t(x)<<16)|uint32_t(y)));
      const int slot=int(group)-1;
      if((fields&1) && px>=10 && px<60 && py>=y+2 && py<y+30)
        return !etaRimMask[slot][(py-y)*54+px-8];
      if((fields&2) && GaugeBezel::inside(px-72,py-y-5,22,22,4))
        return !(bezel.route && bezel.rim(px-72,py-y-5,22,22,4,(72u<<16)|uint32_t(y+5)));
      if((fields&4) && px>=102 && px<165) return true;
      return (fields&8) && px>=181 && px<width-8;
    };
    // Transfer only changed field interiors, excluding every static rim.
    for(int row=0;row<h;++row) {
      auto* line=pixels+(y+row)*width+x;
      int run=-1;
      for(int col=0;col<=w;++col) {
        const bool paint=col<w && dynamicPixel(x+col,y+row);
        if(paint) {
          line[col]=DisplayEffects::fade565(line[col],transitionShell[row*w+col],phase.opacity);
          if(run<0) run=col;
        } else if(run>=0) {
          gfx.draw16bitRGBBitmap(x+run,y+row,line+run,col-run,1);
          run=-1;
        }
      }
    }
    transitionShown[group]=platform;
    transitionShownPage[group]=page;
    transitionPaintedOpacity[group]=phase.opacity;
    transitionPaintedIncoming[group]=phase.incoming;
  }
  drawingTarget=nullptr;
}

void ArrivalScreen::animatePlatform(uint32_t now) {
  if(!setPerformanceMode(PerformanceMode::ACTIVE) || !platformDip.tick(now)) return;
  renderPlatformFrame(now);
  if(!platformDip.active) {
    renderedPlatform=state.current();renderedPage=state.page;hasRendered=true;
    for(size_t slot=0;slot<3;++slot) {
      const size_t index=state.page*3+slot;
      etaFades[slot].reset(index<state.current().arrivalCount ? state.current().arrivals[index].eta : -1);
    }
    // Preserve status identity: changing platforms alone does not repaint it.
    dirty=true;
  }
}
void ArrivalScreen::setPlatforms(const ArrivalBoard& data, uint32_t now) {
  // Update the board immediately. Incoming groups always read this latest state.
  state.setBoard(data,now);
  transitionPaintedOpacity.fill(-1);
  dirty=true;
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
bool ArrivalScreen::animationNeedsPerformance(uint32_t) const {
  if(suspended) return false;
  if(platformDip.active || springBlock.moving()) return true;
  for(const auto& fade:etaFades) if(fade.active) return true;
  return false;
}

void ArrivalScreen::tick(uint32_t now) {
  if (suspended) return;
  if (themeDirty) { drawTheme(now); if (themeDirty) return; }
  if (restartConnectionTimer) { connectionAttemptStarted = now; restartConnectionTimer = false; }
  const bool failed = !connected && uint32_t(now - connectionAttemptStarted) >= CONNECTION_WARNING_MS;
  if (connectionFailed != failed) { connectionFailed = failed; dirty = true; }
  if (platformDip.active) { animatePlatform(now); drawSpring(now); return; }
  const size_t previousPage=state.page;
  if (state.tick(now)) dirty = true;
  if(state.page!=previousPage) {
    beginNavigationTransition(now);
    if(platformDip.active) { animatePlatform(now);drawSpring(now);return; }
  }
  if (dirty) draw(now);
  animateEtas(now);
  drawSpring(now);
}

void ArrivalScreen::suspend(uint32_t now) {
  if (suspended) return;
  clearSpring();
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
  const std::string eta = value<0 ? "" : std::to_string(value);
  surface().setTextWrap(false);
  surface().setTextSize(1);
  surface().setTextColor(etaColor(opacity));
  int16_t bx=0, by=0; uint16_t w=0, h=0;
  // One font for every value. The effect renderer fits both axes together.
  const GFXfont* selected=&FreeSansBoldOblique18pt7b;
  surface().setFont(selected);
  surface().getTextBounds(eta.c_str(),0,0,&bx,&by,&w,&h);
  renderEffectEta(slot,eta,selected,opacity,bx,by,w,h,18);
}

void ArrivalScreen::animateEtas(uint32_t now) {
  bool active=false;
  for (const auto& fade:etaFades) active=active || fade.active;
  if (!hasRendered || !active || !setPerformanceMode(PerformanceMode::ACTIVE)) return;
  for (size_t slot=0; slot<3; ++slot)
    if (etaFades[slot].tick(now))
      drawEta(slot, etaFades[slot].value, etaFades[slot].opacity, true);
}

void ArrivalScreen::drawScreenLip(bool footerOnly) {
  if(!effects.lip) return;
  const int width=surface().width(),height=surface().height();
  const int top=footerOnly ? height-22 : 0;
  const uint16_t shadow=DisplayEffects::scale565(pallete::background(),100-effects.lipShadow);
  const uint16_t highlight=DisplayEffects::scale565(pallete::background(),100+effects.lipHighlight);
  if(!footerOnly) surface().drawFastHLine(0,0,width,shadow);
  surface().drawFastVLine(0,top,height-top,shadow);
  surface().drawFastVLine(width-1,top,height-top,highlight);
  surface().drawFastHLine(0,height-1,width,highlight);
}

void ArrivalScreen::drawFooter(uint32_t now) {
  if(!drawingTarget) {
    if(!navigationCanvas) {
      navigationCanvas.reset(new Arduino_Canvas(gfx.width(),gfx.height(),nullptr));
      if(!navigationCanvas->begin()) { navigationCanvas.reset(); return; }
    }
    drawingTarget=navigationCanvas.get();
    drawFooter(now);
    drawingTarget=nullptr;
    auto* pixels=navigationCanvas->getFramebuffer();
    // Transfer a composed footer; unchanged distance pixels are not touched.
    const bool keepGauge=effects.stable && hasRendered && renderedPage==state.page &&
      renderedPlatform.stationName==state.current().stationName &&
      renderedPlatform.direction==state.current().direction &&
      renderedPlatform.distanceValue==state.current().distanceValue &&
      renderedPlatform.distanceUnit==state.current().distanceUnit;
    const int start=(gfx.width()-120)/2,end=start+120;
    for(int y=gfx.height()-22;y<gfx.height();++y) {
      if(keepGauge) {
        gfx.draw16bitRGBBitmap(0,y,pixels+y*gfx.width(),start,1);
        gfx.draw16bitRGBBitmap(end,y,pixels+y*gfx.width()+end,gfx.width()-end,1);
      } else gfx.draw16bitRGBBitmap(0,y,pixels+y*gfx.width(),gfx.width(),1);
    }
    return;
  }
  const int width=surface().width(), height=surface().height(), padding=8, footer=height-12;
  const auto& platform=state.current();
  surface().fillRect(0, height-22, width, 22, pallete::background());
  drawScreenLip(true);
  springInvalidated=true;
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
      std::max(0, (width-120)/2-8-statusX), warning ? pallete::primaryText() : pallete::secondaryText());
  }
  drawDistanceGauge(platform.distanceValue, platform.distanceUnit);

}

void ArrivalScreen::draw(uint32_t now) {
  if(hasRendered && !drawingTarget) { drawIncrementalFrame(now); return; }
  const uint64_t renderStarted=esp_timer_get_time();
  DiagnosticStore::shared().event(EventCode::DISPLAY_UPDATE_START,LogLevel::Info,state.hasData);
  if (!setPerformanceMode(PerformanceMode::ACTIVE)) return;
  dirty = false;
  const int width=surface().width(), height=surface().height(), padding=8;
  const auto& platform=state.current();
  const bool full = !hasRendered;
  if(full && !drawingTarget) { dirty=true; drawTheme(now); return; }
  const auto updateKind=contentUpdateKind();
  etaContentRepaint.fill(false);
  if(full) drawInstrumentShell();
  if (full || renderedPlatform.stationName!=platform.stationName || renderedPlatform.direction!=platform.direction) {
    surface().fillRect(8,1,width-16,29,pallete::background());
    text(platform.direction, width-103, 23, 85, pallete::secondaryText(), 1, true, &FreeSans12pt7b);
    text(platform.stationName, padding+10, 23, width-129, pallete::primaryText(), 1, false, &BarlowCondensedSemiBold28);
    surface().drawFastHLine(padding,31,width-padding*2,pallete::detail());
    if (state.hasData) DebugLog.printf("[UI] Platform %u/%u: %s / %s\n",
      unsigned(state.platform+1),unsigned(state.data.platformCount),
      platform.stationName.c_str(),platform.direction.c_str());
  }
  const int rowHeight=(height-52)/3;
  for (size_t slot=0;slot<3;++slot) {
    const size_t index=state.page*3+slot;
    const bool present=index<platform.arrivalCount;
    const bool wasPresent=hasRendered && renderedPage*3+slot<renderedPlatform.arrivalCount;
    const int baseline=60+int(slot)*rowHeight;
    if (!present) {
      updateEtaContent(slot,-1,updateKind,now);
      if(!full && wasPresent) {
        surface().fillRect(70,baseline-23,95,32,pallete::background());
        drawLineWindow(slot,nullptr);
        surface().fillRect(181,baseline-23,width-189,32,pallete::background());
      }
      continue;
    }
    const auto& arrival=platform.arrivals[index];
    updateEtaContent(slot,arrival.eta,updateKind,now);

    // Compare nonnumeric cells independently; ETA frames never enter this path.
    const auto& old=renderedPlatform.arrivals[wasPresent ? renderedPage*3+slot : 0];
    if (full || !wasPresent || old.routeLabel != arrival.routeLabel || old.routeColor != arrival.routeColor) {
      if (!full) surface().fillRect(70,baseline-23,95,32,pallete::background());
      drawLineWindow(slot,&arrival);
      text(routeAbbreviation(arrival.routeLabel),102,baseline+2,60,pallete::primaryText(),1,false,&BarlowCondensedSemiBold22);
    }
    if (full || !wasPresent || old.destination != arrival.destination) {
      if (!full) surface().fillRect(181,baseline-23,width-181,32,pallete::background());
      text(arrival.destination,181,baseline+1,width-181-padding,pallete::secondaryText(),1,true,&BarlowCondensedRegular23);
    }
  }
  const auto key=footerKey(now);
  if (full || key != renderedFooter) {
    drawFooter(now); renderedFooter=key; renderedFooterStatus=footerStatusKey(now);
  }
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
  platformDip.cancel(); // A new shell/style supersedes the old transition palette.
  etaRimValid.fill(false);
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
  if(bezel.distance) drawGaugeBezel((width-tabWidth)/2,height-tabHeight,tabWidth,tabHeight+cornerRadius,cornerRadius);
  if(value.empty()) return; // Unknown is a blank instrument, never a fabricated zero.
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
  if(effects.depth) {
    const uint16_t body=DisplayEffects::scale565(pallete::arrivalBadgeText(255),100-effects.depthDarken);
    text(displayValue,startX+effects.depthX,baseline+effects.depthY,fittedWidth,body,1,false,numberFont);
  }
  text(displayValue,startX,baseline,fittedWidth,pallete::arrivalBadgeText(255),1,false,numberFont);
  text(unit,startX+fittedWidth+gap,baseline,unitWidth,pallete::arrivalBadgeText(255),1,false,&ArrivalSans8);
}

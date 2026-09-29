#include "../../../platform/diagnostics/SerialLog.h"
#include "ArrivalScreen.h"
#include <cstdlib>
#include <new>
#include "theme/pallete.h"
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
#include "DisplayDirection.h"

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

void ArrivalScreen::invalidate() {
  platformDip.cancel();
  hasRendered=false;
  etaRimValid.fill(false);
  dirty=themeDirty=true;
}
void ArrivalScreen::applySnapshot(const RenderSnapshot& snapshot,uint32_t now) {
  renderError=nullptr;
  const bool changedStyle=styleRevision!=snapshot.styleRevision || state.compact!=snapshot.board.compact;
  const bool changedSelection=state.platform!=snapshot.board.platform || state.page!=snapshot.board.page;
  if(changedSelection && !changedStyle) beginNavigationTransition(now);
  state=snapshot.board; // Read-only application snapshot; no renderer pagination.
  platformDip.arrivalSlots=visibleSlots();
  pallete::setRenderTheme(snapshot.theme);
  styleRevision=snapshot.styleRevision;
  if(changedStyle || !hasRendered) invalidate();
  setConnected(snapshot.connected);
  setBatteryPercent(snapshot.batteryPercent);
  suspended=snapshot.suspended;
  if(springPhysicalHeld!=snapshot.buttonDown) buttonChanged(snapshot.buttonDown,now);
  dirty=true;
}
bool ArrivalScreen::pending() const {
  if(suspended) return false;
  if(dirty || themeDirty || platformDip.active || springBlock.moving()) return true;
  for(const auto& fade:etaFades) if(fade.active) return true;
  return false;
}
std::string ArrivalScreen::footerKey(uint32_t now) const {
  return footerStatusKey(now)+":"+state.current().distanceValue+":"+state.current().distanceUnit;
}
std::string ArrivalScreen::footerStatusKey(uint32_t now) const {
  const uint32_t age=state.hasData && state.ageMinutes(now)>=STALE_DISPLAY_MINUTES ? state.ageMinutes(now) : 0;
  return std::to_string(connected)+":"+std::to_string(connectionFailed)+":"+
    std::to_string(int(battery))+":"+std::to_string(age);
}

void ArrivalScreen::beginNavigationTransition(uint32_t now) {
  if(!hasRendered || !navigationCanvas) return;
  transitionPaintedOpacity.fill(-1);
  transitionPaintedLights=transitionPaintedNames=transitionPaintedDestinations=-1;
  for(size_t group=0;group<visibleSlots()+2;++group) {
    if(!platformDip.active || platformDip.groups[group].opacity==255) transitionFields[group]=0;
    transitionSource[group]=platformDip.active ? transitionShown[group] : renderedPlatform;
    transitionSourcePage[group]=platformDip.active ? transitionShownPage[group] : renderedPage;
    if(!platformDip.active && group>=1 && group<=visibleSlots()) {
      const size_t slot=group-1,index=renderedPage*visibleSlots()+slot;
      if(index<transitionSource[group].arrivalCount)
        transitionSource[group].arrivals[index].eta=etaFades[slot].value;
    }
    transitionShown[group]=transitionSource[group];
    transitionShownPage[group]=transitionSourcePage[group];
  }
  platformDip.arrivalSlots=visibleSlots();
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
  const int width=gfx.width();
  auto* pixels=navigationCanvas->getFramebuffer();
  const ArrivalDisplay empty{"",0,"",-1};
  for(size_t group=0;group<visibleSlots()+2;++group) {
    const auto& phase=platformDip.groups[group];
    const auto& source=transitionSource[group];
    const auto& target=state.current();
    auto& fields=transitionFields[group];
    // Latch changed fields until completion, including partially faded fields
    // carried across a retarget. Equal fields are never sent to the display.
    if(group==0) {
      if(source.stationName!=target.stationName) fields|=1;
      if(source.direction!=target.direction) fields|=2;
    } else if(group==footerGroup()) {
      if(source.distanceValue!=target.distanceValue || source.distanceUnit!=target.distanceUnit) fields|=1;
    } else {
      const size_t slot=group-1,oldIndex=transitionSourcePage[group]*visibleSlots()+slot,newIndex=state.page*visibleSlots()+slot;
      const auto& a=oldIndex<source.arrivalCount ? source.arrivals[oldIndex] : empty;
      const auto& b=newIndex<target.arrivalCount ? target.arrivals[newIndex] : empty;
      if(a.eta!=b.eta) fields|=1;
      if(a.routeLabel.empty()!=b.routeLabel.empty() ||
          (!a.routeLabel.empty() && !b.routeLabel.empty() && a.routeColor!=b.routeColor)) fields|=2;
      if(routeAbbreviation(a.routeLabel)!=routeAbbreviation(b.routeLabel)) fields|=4;
      if(a.destination!=b.destination) fields|=8;
      fields|=15; // Each arrival cell reveals all its fields on its own clock.
    }
    if(!fields || (transitionPaintedOpacity[group]==phase.opacity &&
        transitionPaintedIncoming[group]==phase.incoming)) continue;
    const auto& platform=phase.incoming ? target : source;
    const size_t page=phase.incoming ? state.page : transitionSourcePage[group];
    const int x=group==footerGroup() ? (width-87)/2 : group==0 ? 8 : cellX(group-1);
    const int y=group==0 ? 1 : group==footerGroup() ? gfx.height()-22 : cellY(group-1);
    const int w=group==footerGroup() ? 87 : group==0 ? width-16 : cellRight(group-1)-x;
    const int h=group==0 ? 29 : group==footerGroup() ? 22 : 32;
    surface().fillRect(x,y,w,h,pallete::background()); // scratch RAM only
    if(group>=1 && group<=visibleSlots()) {
      drawRowShell(group-1);
      // Dark route windows and hidden labels have no placeholder dots.
    }
    if(group==footerGroup()) drawDistanceGauge("","");
    for(int row=0;row<h;++row)
      std::copy_n(pixels+(y+row)*width+x,w,transitionShell.data()+row*w);
    if(group==0) {
      if(fields&2) text(TransitDisplay::displayDirection(platform.direction),width-103,23,85,pallete::secondaryText(),1,true,&FreeSans12pt7b);
      if(fields&1) text(platform.stationName,18,23,width-129,pallete::primaryText(),1,false,&BarlowCondensedSemiBold28);
    } else if(group==footerGroup()) {
      drawDistanceGauge(platform.distanceValue,platform.distanceUnit);
    } else {
      const size_t slot=group-1,index=page*visibleSlots()+slot;
      const auto& arrival=index<platform.arrivalCount ? platform.arrivals[index] : empty;
      const int baseline=cellY(slot)+23;
      if(fields&1) drawEta(slot,arrival.eta,255,false);
      // Route lights use the next page and a shared clock, not this row's text phase.
      const size_t incomingIndex=state.page*visibleSlots()+slot;
      const auto& incoming=incomingIndex<target.arrivalCount ? target.arrivals[incomingIndex] : empty;
      if(fields&2) drawLineWindow(slot,incomingIndex<target.arrivalCount ? &incoming : nullptr);
      if((fields&4) && !incoming.routeLabel.empty()) {
        surface().fillRect(nameX(slot),y,nameRegionWidth(slot),32,pallete::background());
        text(routeAbbreviation(incoming.routeLabel),nameX(slot),baseline+2,nameWidth(slot),pallete::primaryText(),1,false,&BarlowCondensedSemiBold22);
      }
      if(!state.compact && (fields&8)) text(arrival.destination,181,baseline+1,width-189,pallete::secondaryText(),1,true,&BarlowCondensedRegular23);
    }
    const auto dynamicPixel=[&](int px,int py) {
      if(group==0) return ((fields&1) && px>=18 && px<209) || ((fields&2) && px>=width-103 && px<width-18);
      if(group==footerGroup()) return GaugeBezel::inside(px-x,py-y,87,28,6) &&
        !(bezel.distance && bezel.rim(px-x,py-y,87,28,6,(uint32_t(x)<<16)|uint32_t(y)));
      const int slot=int(group)-1;
      if((fields&1) && px>=cellX(slot)+2 && px<cellX(slot)+52 && py>=y+2 && py<y+30)
        return !etaRimMask[slot][(py-y)*54+px-cellX(slot)];
      if((fields&2) && GaugeBezel::inside(px-lineX(slot),py-lineY(slot),routeSize,routeSize,4))
        return !(bezel.route && bezel.rim(px-lineX(slot),py-lineY(slot),routeSize,routeSize,4,
          (uint32_t(lineX(slot))<<16)|uint32_t(lineY(slot))));
      if((fields&4) && px>=nameX(slot) && px<nameX(slot)+nameRegionWidth(slot)) return true;
      return !state.compact && (fields&8) && px>=181 && px<width-8;
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
  if(!platformDip.tick(now)) return;
  renderPlatformFrame(now);
  if(!platformDip.active) {
    renderedPlatform=state.current();renderedPage=state.page;hasRendered=true;
    for(size_t slot=0;slot<visibleSlots();++slot) {
      const size_t index=state.page*visibleSlots()+slot;
      etaFades[slot].reset(index<state.current().arrivalCount ? state.current().arrivals[index].eta : -1);
    }
    // Preserve status identity: changing platforms alone does not repaint it.
    dirty=true;
  }
}
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
  if (suspended || renderError) return;
  if (themeDirty) { drawTheme(now); if (themeDirty) return; }
  if (restartConnectionTimer) { connectionAttemptStarted = now; restartConnectionTimer = false; }
  const bool failed = !connected && uint32_t(now - connectionAttemptStarted) >= CONNECTION_WARNING_MS;
  if (connectionFailed != failed) { connectionFailed = failed; dirty = true; }
  if (platformDip.active) { animatePlatform(now); drawSpring(now); return; }
  if (dirty) draw(now);
  animateEtas(now);
  drawSpring(now);
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

void ArrivalScreen::animateEtas(uint32_t now) {
  bool active=false;
  for (const auto& fade:etaFades) active=active || fade.active;
  if (!hasRendered || !active) return;
  for (size_t slot=0; slot<visibleSlots(); ++slot)
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
      navigationCanvas.reset(new (std::nothrow) Arduino_Canvas(gfx.width(),gfx.height(),nullptr));
      if(!navigationCanvas || !navigationCanvas->begin()) { navigationCanvas.reset(); renderError="framebuffer allocation"; return; }
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
    text(TransitDisplay::displayDirection(platform.direction), width-103, 23, 85, pallete::secondaryText(), 1, true, &FreeSans12pt7b);
    text(platform.stationName, padding+10, 23, width-129, pallete::primaryText(), 1, false, &BarlowCondensedSemiBold28);
    surface().drawFastHLine(padding,31,width-padding*2,pallete::detail());
    if (state.hasData) DebugLog.printf("[UI] Platform %u/%u: %s / %s\n",
      unsigned(state.platform+1),unsigned(state.data.platformCount),
      platform.stationName.c_str(),platform.direction.c_str());
  }
  for (size_t slot=0;slot<visibleSlots();++slot) {
    const size_t index=state.page*visibleSlots()+slot;
    const bool present=index<platform.arrivalCount;
    const bool wasPresent=hasRendered && renderedPage*visibleSlots()+slot<renderedPlatform.arrivalCount;
    const int baseline=cellY(slot)+23;
    if (!present) {
      updateEtaContent(slot,-1,updateKind,now);
      if(!full && wasPresent) {
        surface().fillRect(lineX(slot)-2,baseline-23,routeRegionWidth(slot),32,pallete::background());
        drawLineWindow(slot,nullptr);
        if(!state.compact) surface().fillRect(181,baseline-23,width-189,32,pallete::background());
      }
      continue;
    }
    const auto& arrival=platform.arrivals[index];
    updateEtaContent(slot,arrival.eta,updateKind,now);

    // Compare nonnumeric cells independently; ETA frames never enter this path.
    const auto& old=renderedPlatform.arrivals[wasPresent ? renderedPage*visibleSlots()+slot : 0];
    if (full || !wasPresent || old.routeLabel != arrival.routeLabel || old.routeColor != arrival.routeColor) {
      if (!full) surface().fillRect(lineX(slot)-2,baseline-23,routeRegionWidth(slot),32,pallete::background());
      drawLineWindow(slot,&arrival);
      text(routeAbbreviation(arrival.routeLabel),nameX(slot),baseline+2,nameWidth(slot),pallete::primaryText(),1,false,&BarlowCondensedSemiBold22);
    }
    if (!state.compact && (full || !wasPresent || old.destination != arrival.destination)) {
      if (!full) surface().fillRect(181,baseline-23,width-181,32,pallete::background());
      text(arrival.destination,181,baseline+1,width-181-padding,pallete::secondaryText(),1,true,&BarlowCondensedRegular23);
    }
  }
  const auto key=footerKey(now);
  if (full || key != renderedFooter) {
    drawFooter(now); renderedFooter=key; renderedFooterStatus=footerStatusKey(now);
  }
  renderedPlatform=platform; renderedPage=state.page; hasRendered=true;

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
    navigationCanvas.reset(new (std::nothrow) Arduino_Canvas(gfx.width(), gfx.height(), nullptr));
    if (navigationCanvas && !navigationCanvas->begin()) navigationCanvas.reset();
  }
  if (!navigationCanvas) {
    renderError="framebuffer allocation";
    return;
  }
  drawingTarget = navigationCanvas.get();
  draw(now);
  drawingTarget = nullptr;
  if (dirty || renderError) return;
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

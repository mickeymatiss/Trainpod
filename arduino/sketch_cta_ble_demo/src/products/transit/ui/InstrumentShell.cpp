#include "ArrivalScreen.h"
#include "theme/pallete.h"

// Compose changed content in RAM and transfer only its own cells. ETA values
// are handled separately by their concurrent fade clocks, never by row clears.
void ArrivalScreen::drawIncrementalFrame(uint32_t now) {
  if(!navigationCanvas) return; // Initial shell creation owns canvas allocation.
  const auto previous=renderedPlatform;
  const size_t previousPage=renderedPage;
  const auto previousFooter=renderedFooter;
  const auto previousStatus=renderedFooterStatus;
  drawingTarget=navigationCanvas.get();
  draw(now);
  drawingTarget=nullptr;
  if(dirty) return;
  const auto& current=state.current();
  const int width=gfx.width();
  if(previous.stationName!=current.stationName || previous.direction!=current.direction)
    copyRegion(8,1,width-16,29);
  for(size_t slot=0;slot<visibleSlots();++slot) {
    const size_t oldIndex=previousPage*visibleSlots()+slot,newIndex=state.page*visibleSlots()+slot;
    const bool had=oldIndex<previous.arrivalCount,has=newIndex<current.arrivalCount;
    if(etaContentRepaint[slot]) copyRegion(cellX(slot)+2,cellY(slot)+2,50,28);
    if(!had && !has) continue;
    const int top=cellY(slot);
    const auto& old=previous.arrivals[had ? oldIndex : 0];
    const auto& next=current.arrivals[has ? newIndex : 0];
    if(had!=has || old.routeLabel!=next.routeLabel || old.routeColor!=next.routeColor)
      copyRegion(lineX(slot)-2,top,routeRegionWidth(slot),32);
    if(!state.compact && (had!=has || old.destination!=next.destination))
      copyRegion(181,top,width-189,32);
  }
  if(previousFooter!=renderedFooter) {
    const int left=(width-120)/2,top=gfx.height()-22;
    if(previousStatus!=renderedFooterStatus) {
      copyRegion(0,top,left,22);
      copyRegion(left+120,top,width-left-120,22);
    }
    if(previous.distanceValue!=current.distanceValue || previous.distanceUnit!=current.distanceUnit)
      copyRegion(left,top,120,22);
  }
}

uint16_t ArrivalScreen::neutralLineColor() const {
  return DisplayEffects::mix(pallete::background(),pallete::arrivalBadge(),75);
}

void ArrivalScreen::drawLineWindow(size_t slot,const ArrivalDisplay* arrival) {
  const int baseline=cellY(slot)+23;
  const bool populated=arrival && !arrival->routeLabel.empty();
  const uint16_t color=populated ? pallete::routeColor(*arrival) : neutralLineColor();
  surface().fillRoundRect(lineX(slot),baseline-18,22,22,4,color);
  // Route illumination changes inside a fixed, theme-derived frame.
  if(bezel.route) drawGaugeBezel(lineX(slot),baseline-18,22,22,4,neutralLineColor());
  // Empty/off windows keep only the neutral lens and frame—no dots or route color.
}

void ArrivalScreen::drawRowShell(size_t slot) {
  const int top=cellY(slot);
  surface().fillRoundRect(cellX(slot),top,54,32,10,pallete::arrivalBadge());
  if(bezel.eta) drawGaugeBezel(cellX(slot),top,54,32,10);
  drawLineWindow(slot,nullptr);
}

void ArrivalScreen::drawInstrumentShell() {
  surface().fillScreen(pallete::background());
  drawScreenLip();
  surface().drawFastHLine(8,31,surface().width()-16,pallete::detail());
  for(size_t slot=0;slot<visibleSlots();++slot) drawRowShell(slot);
  drawDistanceGauge("","");
}

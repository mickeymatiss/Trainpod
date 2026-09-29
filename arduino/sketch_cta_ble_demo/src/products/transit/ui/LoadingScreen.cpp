#include "ArrivalScreen.h"
#include <new>

bool ArrivalScreen::drawLoadingOrInitialShell(uint32_t now) {
  if(!state.hasData) {
    if(dirty || themeDirty || !loadingShown) {
      gfx.fillScreen(0);
      gfx.setFont(nullptr);gfx.setTextWrap(false);gfx.setTextSize(2);
      gfx.setTextColor(0xffff);
      int16_t x=0,y=0;uint16_t w=0,h=0;
      gfx.getTextBounds("Loading",0,0,&x,&y,&w,&h);
      gfx.setCursor((gfx.width()-w)/2-x,(gfx.height()-h)/2-y);
      gfx.print("Loading");
    }
    loadingShown=awaitingFirstData=true;
    hasRendered=false;dirty=themeDirty=false;
    platformDip.cancel();
    return true;
  }
  if(!awaitingFirstData) return false;
  if(!navigationCanvas) {
    navigationCanvas.reset(new (std::nothrow) Arduino_Canvas(gfx.width(),gfx.height(),nullptr));
    if(navigationCanvas && !navigationCanvas->begin()) navigationCanvas.reset();
  }
  if(!navigationCanvas) { renderError="framebuffer allocation";return true; }
  // Present the empty instrument frame as a complete image. Content begins
  // on the next worker tick through the normal sequential navigation reveal.
  drawingTarget=navigationCanvas.get();
  drawInstrumentShell();
  drawingTarget=nullptr;
  gfx.draw16bitRGBBitmap(0,0,navigationCanvas->getFramebuffer(),gfx.width(),gfx.height());
  renderedPlatform=PlatformDisplay{};renderedPage=0;hasRendered=true;
  renderedFooter.clear();renderedFooterStatus.clear();
  dirty=themeDirty=false;loadingShown=awaitingFirstData=false;
  beginNavigationTransition(now);
  return true;
}

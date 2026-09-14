#include "ArrivalScreen.h"

// Animation ownership:
// - station/platform or arrival-page navigation: selective field transition
// - same-view data refresh: changed ETA values only, using EtaFade
// - first data / non-navigation replacement view: clean content swap
// - theme/boot: shell composition; button feedback has its own clock
ArrivalScreen::ContentUpdate ArrivalScreen::contentUpdateKind() const {
  if(!hasRendered) return ContentUpdate::InitialShell;
  const auto& current=state.current();
  if(renderedPage!=state.page || renderedPlatform.stationName!=current.stationName ||
      renderedPlatform.direction!=current.direction) return ContentUpdate::Replacement;
  return ContentUpdate::DataRefresh;
}

void ArrivalScreen::updateEtaContent(size_t slot,int next,ContentUpdate kind,uint32_t now) {
  auto& fade=etaFades[slot];
  if(kind==ContentUpdate::DataRefresh) {
    if(next==fade.target) return; // Unchanged data neither redraws nor restarts a fade.
    if(next>=0 && fade.value<0 && !fade.active) fade.appear(next,now);
    else fade.request(next,now); // Redirect to newest value, never queue stale ETAs.
    return;
  }
  const bool repaint=kind==ContentUpdate::InitialShell || fade.value!=next || fade.opacity!=255;
  fade.reset(next); // Replacing a page must not carry a previous row's fade along.
  if(repaint) {
    drawEta(slot,next,255,false);
    etaContentRepaint[slot]=true;
  }
}

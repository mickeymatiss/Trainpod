#include "../src/products/transit/ui/LoadingScreen.cpp"
#include <cassert>
#include <iostream>
static unsigned shells=0,reveals=0;
void ArrivalScreen::drawInstrumentShell() { ++shells;surface().fillScreen(123); }
void ArrivalScreen::beginNavigationTransition(uint32_t now) {
  assert(hasRendered && renderedPlatform.arrivalCount==0);
  ++reveals;platformDip.begin(now);
}
struct ArrivalScreenTest {
  static void run() {
    Arduino_GFX gfx;ArrivalScreen s(gfx);
    assert(s.drawLoadingOrInitialShell(0));
    assert(gfx.ops.size()==2 && gfx.ops[0].kind=="screen" && gfx.ops[0].color==0);
    const auto& label=gfx.ops[1];
    assert(label.kind=="text" && label.color==0xffff);
    assert(label.x*2+label.w==gfx.width() && label.y*2+label.h==gfx.height());
    assert(!s.hasRendered && !s.dirty && !s.themeDirty && !shells && !reveals);
    gfx.ops.clear();assert(s.drawLoadingOrInitialShell(100));assert(gfx.ops.empty());
    s.state.hasData=true;
    assert(s.drawLoadingOrInitialShell(200));
    assert(shells==1 && reveals==1 && s.platformDip.active);
    assert(gfx.ops.size()==1 && gfx.ops[0].kind=="bitmap" && gfx.ops[0].w==320 && gfx.ops[0].h==172);
    gfx.ops.clear();assert(!s.drawLoadingOrInitialShell(225));assert(gfx.ops.empty());
    // A later full redraw/wake retains existing data and skips the loader.
    s.hasRendered=false;s.themeDirty=true;
    assert(!s.drawLoadingOrInitialShell(300));assert(shells==1 && reveals==1);
    // First data may already be available before the renderer's first tick.
    ArrivalScreen ready(gfx);ready.state.hasData=true;
    assert(ready.drawLoadingOrInitialShell(400));assert(shells==2 && reveals==2);
    std::cout<<"PASS centered black loading screen, idle silence, shell before reveal, data-already-ready and wake\n";
  }
};
int main() { ArrivalScreenTest::run(); }

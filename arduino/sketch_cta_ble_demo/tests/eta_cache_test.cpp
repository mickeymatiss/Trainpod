// Host test of the production ETA renderer. Link with dead stripping because
// this translation unit also contains unrelated serial command handlers.
#include "../src/products/transit/ui/DisplayEffects.cpp"
#include <cassert>
#include <iostream>
SerialLog DebugLog(SerialLog::Level::Debug),InfoLog(SerialLog::Level::Info),WarnLog(SerialLog::Level::Warn);
size_t SerialLog::write(const uint8_t*,size_t n) { return n; }
pallete::Theme pallete::activeTheme{},pallete::renderTheme{};
uint16_t pallete::arrivalBadgeText(uint8_t opacity) {
  return DisplayEffects::fade565(color(ArrivalBadgeText),arrivalBadge(),opacity);
}
struct ArrivalScreenTest {
  static void run() {
    Arduino_GFX gfx; ArrivalScreen s(gfx);
    pallete::setRenderTheme({{0x101010,0xffffff,0xffffff,0xaaaaaa,0x303030,0xeeddbc}});
    s.drawEta(0,5,255,false);
    assert(glyphReads>0 && gfx.ops.size()==1 && gfx.boundsCalls==1);
    const auto full=gfx.bitmap;
    const auto cached=s.etaPixels[0];
    const unsigned reads=glyphReads;
    for(int alpha=0;alpha<=255;++alpha) {
      gfx.ops.clear();s.drawEta(0,5,alpha,true);
      assert(glyphReads==reads && gfx.boundsCalls==1);
      assert(gfx.ops.size()==1);
      const auto& op=gfx.ops[0];
      assert(op.kind=="bitmap" && op.x==10 && op.y==39 && op.w==50 && op.h==28);
      assert(s.etaPixels[0]==cached);
      for(int y=0;y<28;++y) for(int x=0;x<50;++x) {
        const int i=y*50+x,source=(y+2)*54+x+2;
        if(s.etaRimMask[0][source]) assert(gfx.bitmap[i]==full[i]);
      }
    }
    assert(gfx.bitmap==full);
    s.drawEta(0,4,0,true);
    assert(glyphReads>reads && gfx.boundsCalls==2);
    const unsigned newReads=glyphReads;
    s.drawEta(0,4,128,true);assert(glyphReads==newReads);
    s.drawEta(0,4,255,true);const auto four=gfx.bitmap;assert(four!=full);
    s.drawEta(0,-1,255,true);const auto blank=gfx.bitmap;
    s.drawEta(0,4,0,true);assert(gfx.bitmap==blank);
    s.drawEta(0,4,255,true);assert(gfx.bitmap==four);
    // All six slots retain independent images, including compact layout.
    s.state.compact=true;s.etaRimValid.fill(false);
    for(size_t i=0;i<6;++i) s.drawEta(i,int(i+10),255,false);
    const unsigned sixReads=glyphReads;
    for(size_t i=0;i<6;++i) s.drawEta(i,int(i+10),100,true);
    assert(glyphReads==sixReads);
    // Style invalidation must rebuild even when the numeric value is unchanged.
    s.effects.bloom=0;s.etaRimValid.fill(false);
    s.drawEta(0,10,255,false);assert(glyphReads>sixReads);
    const auto oldTheme=gfx.bitmap;
    pallete::setRenderTheme({{0x050505,0xffffff,0xffffff,0xaaaaaa,0x080808,0x44ccff}});
    s.etaRimValid.fill(false);s.drawEta(0,10,255,false);
    assert(gfx.bitmap!=oldTheme);
    s.drawEta(0,9999,255,false);s.drawEta(0,1,255,false);
    s.drawEta(0,10,255,false);
    // Navigation draws into a RAM canvas and shares the same cached image.
    Arduino_Canvas canvas(320,172,nullptr);canvas.begin();s.drawingTarget=&canvas;
    const unsigned navReads=glyphReads;
    s.drawEta(0,10,255,false);assert(glyphReads==navReads && canvas.ops.size()==1);
    std::cout<<"PASS cached glyphs across all opacities, one transfer, fixed rim, value swap, blank, six slots, style invalidation, canvas reuse\n";
  }
};
int main() { ArrivalScreenTest::run(); }

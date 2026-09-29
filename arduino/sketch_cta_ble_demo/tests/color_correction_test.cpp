#include "../pallete.h"
#include <cassert>
#include <cstring>
pallete::Theme pallete::activeTheme={};
pallete::Theme pallete::renderTheme={};
int main(){
  pallete::Theme theme={{0x808080,0x527AC7,0xF70000,0x19005D,0,0xFFB485}};
  auto before=theme;
  pallete::setRenderTheme(theme);
  assert(memcmp(&theme,&before,sizeof(theme))==0);
#if KEYTRAIN_COLOR_CORRECTION
  assert(pallete::background()==RGB565(0x7A,0x74,0x5B));
  assert(pallete::primaryText()==RGB565(0x8B,0xA1,0xC9));
  for(auto a:compact_colorscape::anchors) assert(DisplayColor::corrected(a.target)==a.output);
#else
  assert(pallete::background()==RGB565(0x80,0x80,0x80));
#endif
  ArrivalDisplay arrival{};arrival.routeColor=0x527AC7;
  assert(pallete::routeColor(arrival)==pallete::primaryText());
  assert(arrival.routeColor==0x527AC7);
  // Repeated renderer snapshots must not apply the map twice.
  for(int i=0;i<100;++i){pallete::setRenderTheme(theme);assert(pallete::routeColor(arrival)==pallete::primaryText());}
  // Exercise hits and eviction against the uncached engine.
  for(unsigned i=0;i<300;++i){uint32_t rgb=(i*79327)&0xFFFFFF;
#if KEYTRAIN_COLOR_CORRECTION
    assert(DisplayColor::corrected(rgb)==compact_colorscape::correct(rgb));
#else
    assert(DisplayColor::corrected(rgb)==rgb);
#endif
  }
  assert(DisplayColor::corrected(0)==0);
}

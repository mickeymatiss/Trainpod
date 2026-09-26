#include "../src/products/transit/ui/animation/PlatformDip.h"
#include <cassert>
#include <iostream>
int main() {
  PlatformDip d; d.arrivalSlots=6; d.begin(1000);
  assert(d.tick(1000) && d.groups[0].opacity==255 && !d.groups[0].incoming);
  assert(!d.tick(1024)); assert(d.tick(1100) && d.groups[0].opacity==63);
  assert(d.numberOpacity==0 && d.lightOpacity==0);
  d.tick(1200); assert(d.groups[0].opacity==0 && !d.groups[0].incoming);
  d.tick(1275); assert(d.groups[0].incoming && d.numberOpacity==0);
  d.tick(1425); assert(d.numberOpacity==192 && d.lightOpacity==192);
  for(size_t i=1;i<8;++i) assert(d.groups[i].incoming && d.groups[i].opacity==192);
  assert(d.nameOpacity==d.numberOpacity && d.destinationOpacity==d.numberOpacity);
  d.tick(1475); assert(d.groups[0].opacity==255 && d.active && !d.lightReady);
  d.tick(1575); assert(!d.active && d.lightReady && d.numberOpacity==255);
  assert(!d.tick(1600));
  d.begin(2000); d.tick(2100); d.retarget(2100);
  assert(d.groups[0].from==63 && d.numberOpacity==0);
  d.tick(2200); assert(d.groups[0].opacity==15 && !d.groups[0].incoming);
  d.tick(2675); assert(!d.active);
  d.begin(UINT32_MAX-100); d.tick(uint32_t(UINT32_MAX-100+575u)); assert(!d.active);
  d.settings.enabled=false; d.begin(0); d.tick(0); assert(!d.active && d.numberOpacity==255);
  d.settings.enabled=true; d.begin(0); d.cancel(); assert(!d.tick(600));
  std::cout<<"PASS header 200/75/200ms, shared 300ms reveal, 6 slots, retarget, disable/cancel and wrap\n";
}

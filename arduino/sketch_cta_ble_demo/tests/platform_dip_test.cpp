#include "../src/products/transit/ui/animation/PlatformDip.h"
#include <cassert>
#include <iostream>
static void sequence(size_t slots,uint32_t start) {
  PlatformDip d;d.arrivalSlots=slots;d.begin(start);
  assert(d.tick(start));assert(!d.tick(start+24));
  for(uint32_t t=25;t<=275+slots*150;t+=25) {
    assert(d.tick(start+t));unsigned moving=0;
    for(size_t i=0;i<slots;++i) {
      const auto opacity=d.groups[i+1].opacity;
      if(opacity>0 && opacity<255) {
        ++moving;
        for(size_t j=0;j<i;++j) assert(d.groups[j+1].opacity==255);
        for(size_t j=i+1;j<slots;++j) assert(d.groups[j+1].opacity==0);
      }
      const uint32_t rowStart=275+uint32_t(i)*150;
      if(t<=rowStart) assert(opacity==0);
      if(t>=rowStart+150) assert(opacity==255);
    }
    assert(moving<=1);assert(d.active==(t<275+slots*150));
  }
  assert(!d.tick(start+2000));
}
int main() {
  sequence(3,1000);sequence(6,1000);sequence(6,UINT32_MAX-100);
  PlatformDip d;d.begin(0);d.tick(0);d.tick(275);d.tick(350);
  assert(d.groups[1].opacity>0 && d.groups[2].opacity==0);
  // A stall finishes only the current cell, without advancing other cells.
  d.tick(2000);assert(d.groups[1].opacity==255 && d.groups[2].opacity==0 && d.active);
  d.tick(2025);assert(d.groups[2].opacity>0 && d.groups[3].opacity==0);
  // A new navigation target replaces all pending cells.
  d.retarget(2025);d.tick(2025);
  for(size_t i=1;i<=3;++i) assert(d.groups[i].opacity==0);
  d.settings.enabled=false;d.tick(2026);assert(!d.active);
  for(size_t i=1;i<=3;++i) assert(d.groups[i].opacity==255);
  d.settings.enabled=true;d.begin(3000);d.cancel();assert(!d.tick(3500));
  std::cout<<"PASS sequential 150ms cells, 3/6 slots, stalls, retarget, disable and wrap\n";
}

#include "../src/products/transit/ui/animation/PlatformDip.h"
#include <cassert>
#include <iostream>
int main() {
  PlatformDip dip;dip.begin(0);
  assert(!dip.tick(34));
  const uint8_t expected[]={179,89,89,179,255};
  for(int i=0;i<5;++i){assert(dip.tick((i+1)*35));assert(dip.opacity()==expected[i]);assert(dip.swaps()==(i==2));}
  assert(!dip.active && !dip.tick(210));
  dip.begin(300);dip.tick(335);dip.retarget(340);assert(dip.step==1);
  dip.tick(370);dip.tick(405);assert(dip.swaps());
  dip.tick(440);dip.retarget(445);assert(dip.active && dip.step==1);
  dip.tick(480);assert(dip.opacity()==89 && !dip.swaps());
  dip.tick(515);assert(dip.swaps() && dip.opacity()==89);
  dip.tick(550);dip.tick(585);assert(!dip.active);
  dip.begin(UINT32_MAX-10);assert(dip.tick(24));assert(dip.opacity()==179);
  std::cout<<"PASS 175ms dip, 35% minimum, swap only at minimum, latest-target recovery, millis wrap\n";
}

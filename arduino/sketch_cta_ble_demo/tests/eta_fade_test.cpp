#include "../src/products/transit/ui/animation/EtaFade.h"
#include <cassert>
#include <iostream>
int main() {
  EtaFade fade; fade.reset(5); fade.request(5,0);
  assert(!fade.active && !fade.tick(25));
  fade.request(4,0);
  assert(!fade.tick(24));
  for(uint32_t t=25;t<=100;t+=25) {
    const auto old=fade.opacity; assert(fade.tick(t));
    assert(fade.value==5 && fade.opacity<old);
  }
  assert(fade.tick(125) && fade.opacity==0 && fade.value==4);
  for(uint32_t t=150;t<=250;t+=25) assert(fade.tick(t));
  assert(!fade.active && fade.value==4 && fade.opacity==255);
  assert(!fade.tick(300));
  fade.request(3,300); fade.tick(350); fade.request(2,360);
  assert(fade.tick(425) && fade.value==2 && fade.opacity==0);
  fade.tick(450); const auto alpha=fade.opacity;
  fade.request(1,450); assert(fade.opacity==alpha);
  assert(fade.tick(575) && fade.value==1 && fade.opacity==0);
  fade.tick(700); assert(!fade.active && fade.value==1);
  fade.reset(9); fade.request(10,UINT32_MAX-100);
  assert(fade.tick(24) && fade.value==10 && fade.opacity==0);
  assert(fade.tick(149) && !fade.active && fade.opacity==255);
  EtaFade a,b,c; a.reset(3);b.reset(8);c.reset(14);
  a.request(2,0);b.request(8,0);c.request(13,0);
  for(uint32_t t=25;t<=250;t+=25) {
    assert(a.tick(t) && c.tick(t)); assert(!b.tick(t));
    assert(a.opacity==c.opacity);
  }
  assert(a.value==2 && b.value==8 && c.value==13);
  std::cout<<"PASS fade timing, unchanged values, invisible swap, retarget in both phases, concurrent updates, millis wrap\n";
}

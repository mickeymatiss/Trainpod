#pragma once
#include <array>
#include <stddef.h>
#include <stdint.h>

// Station/platform and arrival-page navigation; never started by data refresh.
// Header, three arrival rows, distance. Timings are snapshotted per transition.
class PlatformDip {
public:
  struct Settings { bool enabled=true; int outMs=200,inMs=200,stagger=75,gap=75; } settings;
  struct Group { uint8_t opacity=255,from=255; bool incoming=false; };
  std::array<Group,5> groups{};
  bool active=false;
  void begin(uint32_t now) {
    for(auto& g:groups) g=Group{};
    active=true;started=now;lastFrame=now-25;running=settings;
  }
  void retarget(uint32_t now) {
    for(auto& g:groups) { g.from=g.opacity; g.incoming=false; }
    active=true;started=now;lastFrame=now-25;running=settings;
  }
  bool tick(uint32_t now) {
    const uint32_t duration=running.outMs+running.gap+running.inMs+4*running.stagger;
    if(!active || (settings.enabled && uint32_t(now-lastFrame)<25 && uint32_t(now-started)<duration)) return false;
    lastFrame=now;
    bool complete=true;
    for(size_t i=0;i<groups.size();++i) {
      auto& g=groups[i];
      const int elapsed=int(uint32_t(now-started))-int(i)*running.stagger;
      const int inStart=running.outMs+running.gap;
      if(!settings.enabled) { g.incoming=true;g.opacity=255;continue; }
      if(elapsed<0) { g.opacity=g.from;g.incoming=false; }
      else if(elapsed<running.outMs) {
        const uint32_t remaining=running.outMs-elapsed;
        g.opacity=uint32_t(g.from)*remaining*remaining/(running.outMs*running.outMs);
        g.incoming=false;
      } else if(elapsed<inStart) { g.opacity=0;g.incoming=false; }
      else {
        g.incoming=true;
        const int t=elapsed-inStart;
        g.opacity=t>=running.inMs ? 255 : 255-(255u*(running.inMs-t)*(running.inMs-t))/(running.inMs*running.inMs);
      }
      if(elapsed<inStart+running.inMs) complete=false;
    }
    active=!complete;
    return true;
  }
  void cancel() { active=false; }
private:
  Settings running;
  uint32_t started=0,lastFrame=0;
};

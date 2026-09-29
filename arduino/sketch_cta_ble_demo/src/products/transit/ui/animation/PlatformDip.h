#pragma once
#include <array>
#include <stddef.h>
#include <stdint.h>

// Station/platform and arrival-page navigation; never started by data refresh.
// Header retains its timing. Arrival cells reveal one at a time.
class PlatformDip {
public:
  struct Settings { bool enabled=true; int outMs=200,inMs=200,stagger=75,gap=75; } settings;
  struct Group { uint8_t opacity=255,from=255; bool incoming=false; };
  std::array<Group,8> groups{};
  size_t arrivalSlots=3;
  static constexpr uint32_t ROW_IN_MS=150;
  static constexpr uint32_t LIGHT_IN_MS=300;
  static constexpr uint32_t NAME_START_MS=0,DESTINATION_START_MS=0,NUMBER_START_MS=0;
  static constexpr uint32_t CONTENT_IN_MS=300,NUMBER_IN_MS=300;
  uint8_t nameOpacity=255,destinationOpacity=255,numberOpacity=255;
  uint8_t lightOpacity=255;
  static uint8_t reveal(uint32_t elapsed,uint32_t start,uint32_t duration=CONTENT_IN_MS) {
    if(elapsed<=start)return 0;
    if(elapsed-start>=duration)return 255;
    const uint32_t remaining=duration-(elapsed-start);
    return 255-(255u*remaining*remaining)/(duration*duration);
  }
  bool lightReady=true;
  bool active=false;
  void begin(uint32_t now) {
    for(auto& g:groups) g=Group{};
    lightOpacity=nameOpacity=destinationOpacity=numberOpacity=0;lightReady=false;
    active=true;started=now;lastFrame=now-25;running=settings;
    rowCursor=0;rowClock=false;
  }
  void retarget(uint32_t now) {
    for(auto& g:groups) { g.from=g.opacity; g.incoming=false; }
    lightOpacity=nameOpacity=destinationOpacity=numberOpacity=0;lightReady=false;
    active=true;started=now;lastFrame=now-25;running=settings;
    rowCursor=0;rowClock=false;
  }
  bool tick(uint32_t now) {
    const uint32_t fieldsDuration=running.outMs+running.gap+running.inMs;
    const uint32_t lightStart=running.outMs+running.gap;
    const uint32_t lightsDuration=lightStart+LIGHT_IN_MS;
    const uint32_t contentDuration=lightStart+DESTINATION_START_MS+CONTENT_IN_MS;
    if(!active || (settings.enabled && uint32_t(now-lastFrame)<25)) return false;
    lastFrame=now;
    // Header and distance retain their clocks; each arrival owns its opacity.
    const uint32_t elapsed=uint32_t(now-started);
    if(elapsed>=lightStart && !rowClock) { rowClock=true;rowStarted=now; }
    // Finish this cell on screen before allowing the next cell to advance.
    // A delayed frame cannot jump ahead through several queued animations.
    if(rowClock && rowCursor<arrivalSlots && uint32_t(now-rowStarted)>=ROW_IN_MS) {
      ++rowCursor;rowStarted=now;
    }
    lightReady=!settings.enabled || elapsed>=lightsDuration;
    if(lightReady) lightOpacity=255;
    else if(elapsed<=lightStart) lightOpacity=0;
    else {
      const uint32_t remaining=LIGHT_IN_MS-(elapsed-lightStart);
      lightOpacity=255-(255u*remaining*remaining)/(LIGHT_IN_MS*LIGHT_IN_MS);
    }
    nameOpacity=settings.enabled ? reveal(elapsed,lightStart+NAME_START_MS) : 255;
    destinationOpacity=settings.enabled ? reveal(elapsed,lightStart+DESTINATION_START_MS) : 255;
    numberOpacity=settings.enabled ? reveal(elapsed,lightStart+NUMBER_START_MS,NUMBER_IN_MS) : 255;
    bool complete=!settings.enabled || elapsed>=contentDuration;
    if(settings.enabled && rowCursor<arrivalSlots) complete=false;
    for(size_t i=0;i<arrivalSlots+2;++i) {
      auto& g=groups[i];
      // Arrival cells and changed distance share the same 0..300 ms reveal.
      // The renderer skips distance entirely when its value/unit is unchanged.
      if(i>=1) {
        g.incoming=true;
        if(i>arrivalSlots) g.opacity=numberOpacity;
        else {
          const size_t slot=i-1;
          g.opacity=!settings.enabled || slot<rowCursor ? 255 :
            slot==rowCursor && rowClock ? reveal(uint32_t(now-rowStarted),0,ROW_IN_MS) : 0;
        }
        continue;
      }
      const int elapsed=int(uint32_t(now-started)); // Header only; no distance stagger.
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
  size_t rowCursor=0;
  uint32_t rowStarted=0;
  bool rowClock=false;
};

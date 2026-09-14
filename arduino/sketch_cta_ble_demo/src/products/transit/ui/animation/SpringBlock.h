#pragma once
#include <stdint.h>

// Physical target controls motion; interruption starts from the current position.
struct SpringBlock {
  struct Settings {
    int enabled=1, width=50, height=17, depth=10, radius=7;
    int pressMs=350, releaseMs=120, debug=0;
  } settings;
  enum class State { Retracted, Pressing, Held, Releasing };
  State state=State::Retracted;
  float position=0, target=0, from=0;
  uint32_t started=0;
  bool pressed=false;

  bool moving() const { return state==State::Pressing || state==State::Releasing; }
  void update(uint32_t now) {
    if(!moving()) return;
    const uint32_t duration=state==State::Pressing ? settings.pressMs : settings.releaseMs;
    const uint32_t elapsed=now-started;
    if(elapsed>=duration) {
      position=target;
      state=pressed ? State::Held : State::Retracted;
      return;
    }
    const float t=float(elapsed)/duration;
    const float eased=state==State::Pressing ? 1-(1-t)*(1-t)*(1-t) : t*t*(3-2*t);
    position=from+(target-from)*eased;
  }
  void setPressed(bool down,uint32_t now) {
    update(now);
    down=down && settings.enabled;
    const float wanted=down ? settings.depth : 0;
    if(down==pressed && wanted==target) return;
    pressed=down; target=wanted; from=position; started=now;
    state=position==target ? (down ? State::Held : State::Retracted) :
      (down ? State::Pressing : State::Releasing);
  }
  void reset() { position=target=from=0; pressed=false; state=State::Retracted; }
};

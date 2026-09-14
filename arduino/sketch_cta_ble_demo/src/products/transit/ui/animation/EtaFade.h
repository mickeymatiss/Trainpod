#pragma once
#include <stdint.h>

// Independent of the display driver; millis arithmetic also handles wraparound.
class EtaFade {
public:
  static constexpr uint32_t HalfDurationMs = 125, FrameMs = 25;
  int value = 0, target = 0;
  uint8_t opacity = 255;
  bool active = false;
  void reset(int next) { value = target = next; opacity = 255; active = false; }
  void appear(int next,uint32_t now) {
    value=target=next;opacity=0;active=true;fadingIn=true;
    started=lastFrame=now;
  }
  void request(int next, uint32_t now) {
    if (next == target) return;
    target = next;
    if (active && !fadingIn) return; // Replace the pending value before the invisible swap.
    active = true; fadingIn = false; started = lastFrame = now; fromOpacity = opacity;
  }
  bool tick(uint32_t now) {
    if (!active || uint32_t(now-lastFrame) < FrameMs) return false;
    lastFrame = now;
    const uint32_t elapsed = now-started;
    if (!fadingIn) {
      if (elapsed >= HalfDurationMs) {
        value = target; opacity = 0; fadingIn = true; started = now;
      } else opacity = uint32_t(fromOpacity) * (HalfDurationMs-elapsed) / HalfDurationMs;
    } else if (elapsed >= HalfDurationMs) {
      value = target; opacity = 255; active = false;
    } else opacity = 255 * elapsed / HalfDurationMs;
    return true;
  }
private:
  bool fadingIn = false;
  uint8_t fromOpacity = 255;
  uint32_t started = 0, lastFrame = 0;
};

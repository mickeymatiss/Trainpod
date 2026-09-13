#pragma once
#include <stdint.h>

class PlatformDip {
public:
  static constexpr uint32_t StepMs=35;
  bool active=false;
  uint8_t step=0;
  void begin(uint32_t now) { active=true; step=0; lastFrame=now; }
  void retarget(uint32_t now) {
    // Already recovering: return to the next minimum, never queue another trip.
    if (step>=3) { step=1; lastFrame=now; }
  }
  bool tick(uint32_t now) {
    if (!active || uint32_t(now-lastFrame)<StepMs) return false;
    lastFrame=now; ++step;
    if (step==5) active=false;
    return true;
  }
  bool swaps() const { return step==3; }
  uint8_t opacity() const { return step==1 || step==4 ? 179 : step==2 || step==3 ? 89 : 255; }
  void cancel() { active=false;step=0; }
private:
  uint32_t lastFrame=0;
};

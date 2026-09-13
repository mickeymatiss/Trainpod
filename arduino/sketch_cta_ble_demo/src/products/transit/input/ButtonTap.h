#pragma once
#include <stdint.h>

// Receives debounced presses. Defer singles so a double never navigates twice.
class ButtonTap {
public:
  enum class Action { None, Platform, Station };
  static constexpr uint32_t DoubleTapMs = 300;
  Action press(uint32_t now) {
    if (pending && uint32_t(now - firstPress) <= DoubleTapMs) {
      pending = false;
      return Action::Station;
    }
    const bool overdue = pending;
    pending = true; firstPress = now;
    return overdue ? Action::Platform : Action::None;
  }
  Action tick(uint32_t now) {
    if (!pending || uint32_t(now - firstPress) <= DoubleTapMs) return Action::None;
    pending = false;
    return Action::Platform;
  }
  void reset() { pending = false; }
private:
  bool pending = false;
  uint32_t firstPress = 0;
};

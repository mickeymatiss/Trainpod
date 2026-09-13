#pragma once
#include <stdint.h>

namespace PowerConfig {
constexpr uint32_t ACTIVE_TIMEOUT_MS = 30000;
constexpr uint32_t DIM_TIMEOUT_MS = 30000;
constexpr uint32_t BACKLIGHT_FADE_MS = 1000;
constexpr uint32_t BUTTON_DEBOUNCE_MS = 40;
// Existing PWM range is 0–255; 5 is approximately 17% of normal brightness.
constexpr uint8_t ACTIVE_BRIGHTNESS = 80;
constexpr uint8_t DIM_BRIGHTNESS = 5;
}

enum class PowerState { ACTIVE, DIMMED, SCREEN_OFF_STANDBY };
enum class PowerButtonAction { NAVIGATE, WAKE_ONLY };

// One state-owned timer. No BLE, data, redraw or app event can reset inactivity.
// Hardware effects are supplied separately, so real sleep can replace standby later.
class PowerLifecycle {
public:
  using TransitionHandler = void (*)(PowerState previous, PowerState next, uint32_t now);
  explicit PowerLifecycle(TransitionHandler handler) : handler_(handler) {}

  void begin(uint32_t now) {
    state_ = PowerState::ACTIVE;
    enteredAt_ = now;
    handler_(state_, state_, now);
  }

  PowerButtonAction buttonPressed(uint32_t now) {
    if (state_ == PowerState::ACTIVE) {
      enteredAt_ = now;
      return PowerButtonAction::NAVIGATE;
    }
    transition(PowerState::ACTIVE, now);
    return PowerButtonAction::WAKE_ONLY;
  }

  void tick(uint32_t now) {
    const uint32_t elapsed = now - enteredAt_;
    if (state_ == PowerState::ACTIVE && elapsed >= PowerConfig::ACTIVE_TIMEOUT_MS)
      transition(PowerState::DIMMED, now);
    else if (state_ == PowerState::DIMMED && elapsed >= PowerConfig::DIM_TIMEOUT_MS)
      transition(PowerState::SCREEN_OFF_STANDBY, now);
  }

  PowerState state() const { return state_; }
  bool isStandby() const { return state_ == PowerState::SCREEN_OFF_STANDBY; }

private:
  void transition(PowerState next, uint32_t now) {
    const PowerState previous = state_;
    state_ = next;
    enteredAt_ = now; // Replaces the previous state's timer.
    handler_(previous, next, now);
  }
  TransitionHandler handler_;
  PowerState state_ = PowerState::ACTIVE;
  uint32_t enteredAt_ = 0;
};

#pragma once
#include <Arduino.h>

// Loop-driven PWM fades. Retarget from the current level when a press interrupts a fade.
class BacklightFade {
public:
  explicit BacklightFade(uint8_t pin) : pin_(pin) {}
  void begin() {
    pinMode(pin_, OUTPUT);
    analogWrite(pin_, 0);
  }
  void fadeTo(uint8_t target, uint32_t now, uint32_t duration) {
    update(now);
    if (target == target_) return;
    from_ = level_;
    target_ = target;
    started_ = now;
    duration_ = duration;
    fading_ = true;
    update(now);
  }
  void update(uint32_t now) {
    if (!fading_) return;
    const uint32_t elapsed = now - started_;
    if (duration_ == 0 || elapsed >= duration_) {
      level_ = target_;
      fading_ = false;
    } else {
      const float t = float(elapsed) / duration_;
      const float eased = t * t * (3.0f - 2.0f * t);
      level_ = from_ + (float(target_) - from_) * eased;
    }
    const uint8_t duty = uint8_t(level_ + 0.5f);
    if (duty != written_) {
      analogWrite(pin_, duty);
      written_ = duty;
    }
  }
private:
  uint8_t pin_, target_ = 0, written_ = 0;
  float from_ = 0, level_ = 0;
  uint32_t started_ = 0, duration_ = 0;
  bool fading_ = false;
};

#pragma once

#include <Arduino.h>
#include <Arduino_GFX_Library.h>

class PlatformSplitAnimation {
 public:
  explicit PlatformSplitAnimation(Arduino_GFX* display);

  void begin(uint32_t now);
  void update(uint32_t now);
  void stop();
  bool isRunning() const;

 private:
  Arduino_GFX* gfx;
  bool running;
  uint32_t startedMs;
  uint32_t lastFrameMs;
  uint32_t lastWave;
  uint16_t lastProgress;

  uint32_t tileHash(int column, int row, uint32_t wave) const;
  bool isMonogramTile(int column, int row) const;
  uint16_t tileColor(
    int column,
    int row,
    uint32_t wave,
    const uint16_t palette[5]
  ) const;
  int32_t flipThreshold(int column, int row, uint32_t wave) const;
  void drawTile(int column, int row, uint16_t color, int height);
  void drawFullField(const uint16_t palette[5], uint32_t wave);
};

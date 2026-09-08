#include "PlatformSplitAnimation.h"

namespace {
constexpr int SCREEN_WIDTH = 320;
// Leave the firmware's 21-pixel status bar visible throughout loading.
constexpr int SCREEN_HEIGHT = 151;
constexpr int CELL_SIZE = 7;
constexpr int TILE_SIZE = 5;
constexpr int COLUMN_COUNT = (SCREEN_WIDTH + CELL_SIZE - 1) / CELL_SIZE;
constexpr int ROW_COUNT = (SCREEN_HEIGHT + CELL_SIZE - 1) / CELL_SIZE;
constexpr int MAX_DIAGONAL = (COLUMN_COUNT - 1) + (ROW_COUNT - 1);
constexpr int MONOGRAM_WIDTH = 12;
constexpr int MONOGRAM_HEIGHT = 7;
constexpr int MONOGRAM_COLUMN = (COLUMN_COUNT - MONOGRAM_WIDTH) / 2;
constexpr int MONOGRAM_ROW = (ROW_COUNT - MONOGRAM_HEIGHT) / 2;
constexpr uint32_t ANIMATION_SEED = 871;
constexpr uint32_t FRAME_INTERVAL_MS = 40;  // 25 FPS
constexpr int32_t FLIP_HALF_SPAN = 1600;
constexpr int32_t SCATTER_PER_TILE = 655;   // 0.69 of one diagonal cell

constexpr uint16_t SWAMP_GREEN[5] = {
  0x5B8B, 0x6C0D, 0x746E, 0x84D0, 0x9532
};

constexpr uint16_t SAPPHIRE[5] = {
  0x1231, 0x1273, 0x1AB5, 0x3356, 0x4BD7
};

constexpr uint16_t BACKGROUND_COLOR = 0x0000;
constexpr uint16_t MONOGRAM_COLOR = 0xFFFE;

constexpr uint8_t M_BITMAP[7] = {
  0b10001,
  0b11011,
  0b10101,
  0b10101,
  0b10001,
  0b10001,
  0b10001
};
}

PlatformSplitAnimation::PlatformSplitAnimation(Arduino_GFX* display)
  : gfx(display),
    running(false),
    startedMs(0),
    lastFrameMs(0),
    lastWave(0),
    lastProgress(0) {}

void PlatformSplitAnimation::begin(uint32_t now) {
  startedMs = now;
  lastFrameMs = now - FRAME_INTERVAL_MS;
  lastWave = 0;
  lastProgress = 0;
  running = true;

  // Wave zero brings in swamp green, so the initial field is sapphire.
  gfx->fillRect(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT, BACKGROUND_COLOR);
  drawFullField(SAPPHIRE, 0);
}

void PlatformSplitAnimation::update(uint32_t now) {
  if (!running || static_cast<uint32_t>(now - lastFrameMs) < FRAME_INTERVAL_MS) {
    return;
  }
  lastFrameMs = now;

  const uint32_t elapsedMs = static_cast<uint32_t>(now - startedMs);
  // globalPhase = elapsedMs * 0.35 / 4000 * 2, represented as Q16.
  const uint64_t phaseQ16 = (static_cast<uint64_t>(elapsedMs) * 45875ULL) / 4000ULL;
  const uint32_t wave = static_cast<uint32_t>(phaseQ16 >> 16);
  const uint16_t progress = static_cast<uint16_t>(phaseQ16 & 0xFFFF);

  if (wave != lastWave) {
    const uint16_t* outgoingPalette = (wave & 1) ? SWAMP_GREEN : SAPPHIRE;
    drawFullField(outgoingPalette, wave - 1);
    lastWave = wave;
    lastProgress = 0;
  }

  const uint16_t* outgoingPalette = (wave & 1) ? SWAMP_GREEN : SAPPHIRE;
  const uint16_t* incomingPalette = (wave & 1) ? SAPPHIRE : SWAMP_GREEN;

  for (int row = 0; row < ROW_COUNT; ++row) {
    for (int column = 0; column < COLUMN_COUNT; ++column) {
      const int32_t threshold = flipThreshold(column, row, wave);
      const int32_t previousLocal = static_cast<int32_t>(lastProgress) - threshold;
      const int32_t local = static_cast<int32_t>(progress) - threshold;

      const bool inFlip = local >= -FLIP_HALF_SPAN && local <= FLIP_HALF_SPAN;
      const bool crossedEnd = previousLocal < FLIP_HALF_SPAN && local > FLIP_HALF_SPAN;
      if (!inFlip && !crossedEnd) continue;

      const int cellY = row * CELL_SIZE;
      const int fullHeight = min(TILE_SIZE, SCREEN_HEIGHT - cellY);
      int height = fullHeight;
      uint16_t color;

      if (isMonogramTile(column, row)) {
        color = MONOGRAM_COLOR;
      } else if (local < 0) {
        color = tileColor(column, row, wave == 0 ? 0 : wave - 1, outgoingPalette);
      } else {
        color = tileColor(column, row, wave, incomingPalette);
      }

      if (inFlip) {
        const int32_t distance = local < 0 ? -local : local;
        height = 1 + ((fullHeight - 1) * distance) / FLIP_HALF_SPAN;
      }

      drawTile(column, row, color, height);
    }
  }

  lastProgress = progress;
}

void PlatformSplitAnimation::stop() {
  running = false;
}

bool PlatformSplitAnimation::isRunning() const {
  return running;
}

uint32_t PlatformSplitAnimation::tileHash(
  int column,
  int row,
  uint32_t wave
) const {
  uint32_t value = ANIMATION_SEED;
  value ^= static_cast<uint32_t>(column) * 0x45D9F3Bu;
  value ^= static_cast<uint32_t>(row) * 0x119DE1F3u;
  value ^= wave * 0x27D4EB2Du;
  value ^= value >> 16;
  value *= 0x7FEB352Du;
  value ^= value >> 15;
  return value;
}

bool PlatformSplitAnimation::isMonogramTile(int column, int row) const {
  const int localColumn = column - MONOGRAM_COLUMN;
  const int localRow = row - MONOGRAM_ROW;
  if (localRow < 0 || localRow >= MONOGRAM_HEIGHT) return false;

  int letterColumn;
  if (localColumn >= 0 && localColumn < 5) {
    letterColumn = localColumn;
  } else if (localColumn >= 7 && localColumn < 12) {
    letterColumn = localColumn - 7;
  } else {
    return false;
  }

  return (M_BITMAP[localRow] & (1 << (4 - letterColumn))) != 0;
}

uint16_t PlatformSplitAnimation::tileColor(
  int column,
  int row,
  uint32_t wave,
  const uint16_t palette[5]
) const {
  return palette[tileHash(column, row, wave) % 5];
}

int32_t PlatformSplitAnimation::flipThreshold(
  int column,
  int row,
  uint32_t wave
) const {
  const int32_t diagonal = column + row;
  int32_t threshold = (diagonal * 65535L) / MAX_DIAGONAL;
  const int32_t signedNoise = static_cast<int32_t>(tileHash(column, row, wave) & 0xFFFF) - 32768;
  threshold += (signedNoise * SCATTER_PER_TILE) / 32768;
  return constrain(threshold, 0L, 65535L);
}

void PlatformSplitAnimation::drawTile(
  int column,
  int row,
  uint16_t color,
  int height
) {
  const int x = column * CELL_SIZE;
  const int y = row * CELL_SIZE;
  const int width = min(TILE_SIZE, SCREEN_WIDTH - x);
  const int fullHeight = min(TILE_SIZE, SCREEN_HEIGHT - y);
  if (width <= 0 || fullHeight <= 0) return;

  gfx->fillRect(x, y, width, fullHeight, BACKGROUND_COLOR);
  const int drawY = y + (fullHeight - height) / 2;
  gfx->fillRect(x, drawY, width, height, color);
}

void PlatformSplitAnimation::drawFullField(
  const uint16_t palette[5],
  uint32_t wave
) {
  for (int row = 0; row < ROW_COUNT; ++row) {
    for (int column = 0; column < COLUMN_COUNT; ++column) {
      const int cellY = row * CELL_SIZE;
      const int height = min(TILE_SIZE, SCREEN_HEIGHT - cellY);
      const uint16_t color = isMonogramTile(column, row)
        ? MONOGRAM_COLOR
        : tileColor(column, row, wave, palette);
      drawTile(column, row, color, height);
    }
  }
}

#pragma once
#include <array>
#include <string>
#include <stdint.h>
#include <algorithm>

struct ArrivalDisplay {
  std::string routeLabel;
  uint32_t routeColor = 0xffffff;
  std::string destination;
  int eta = 0;
};

struct PlatformDisplay {
  std::string stationName;
  std::string direction;
  std::array<ArrivalDisplay, 9> arrivals;
  size_t arrivalCount = 0;
};

struct ArrivalBoard {
  std::array<PlatformDisplay, 4> platforms;
  size_t platformCount = 0;
};

enum class BatteryState { unknown, healthy, caution, low };

// Timing has no dependency on Arduino, BLE, CTA or wall-clock time.
class ArrivalScreenState {
public:
  void setBoard(const ArrivalBoard& board, uint32_t now) {
    const std::string oldDirection = data.platforms[platform].direction;
    const std::string oldStation = data.platforms[platform].stationName;
    data = board;
    platform = 0;
    for (size_t i = 0; i < data.platformCount; ++i)
      if (data.platforms[i].direction == oldDirection && data.platforms[i].stationName == oldStation) platform = i;
    page = 0; pageStarted = now; received = now; hasData = true;
  }
  void nextPlatform(uint32_t now) {
    if (data.platformCount) platform = (platform + 1) % data.platformCount;
    page = 0; pageStarted = now;
  }
  size_t pageCount() const { return std::max(size_t(1), (std::min(size_t(9), current().arrivalCount) + 2) / 3); }
  bool tick(uint32_t now) {
    bool changed = false;
    if (pageCount() > 1 && uint32_t(now - pageStarted) >= 5000) {
      page = (page + uint32_t(now - pageStarted) / 5000) % pageCount();
      pageStarted += (uint32_t(now - pageStarted) / 5000) * 5000;
      changed = true;
    }
    if (uint32_t(now - clockAdvanced) >= 15000) {
      clockFrame = (clockFrame + uint32_t(now - clockAdvanced) / 15000) % 4;
      clockAdvanced += (uint32_t(now - clockAdvanced) / 15000) * 15000;
      changed = true;
    }
    const uint32_t age = ageMinutes(now);
    if (age != drawnAge) { drawnAge = age; changed = true; }
    return changed;
  }
  uint32_t ageMinutes(uint32_t now) const { return hasData ? uint32_t(now - received) / 60000 : 0; }
  const PlatformDisplay& current() const { return data.platforms[platform]; }
  ArrivalBoard data;
  size_t platform = 0, page = 0;
  uint32_t received = 0, pageStarted = 0, clockAdvanced = 0, drawnAge = 0;
  uint8_t clockFrame = 0;
  bool hasData = false;
};

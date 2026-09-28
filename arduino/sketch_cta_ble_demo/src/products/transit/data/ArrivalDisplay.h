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
  std::string distanceValue; // Phone-normalized integer feet or one-decimal miles.
  std::string distanceUnit = "mi"; // Empty value means unknown.
  std::array<ArrivalDisplay, 9> arrivals;
  size_t arrivalCount = 0;
};

struct ArrivalBoard {
  static constexpr size_t MaximumPlatforms = 8; // n: normalized pages, no agency logic.
  std::array<PlatformDisplay, MaximumPlatforms> platforms;
  size_t platformCount = 0;
};

enum class BatteryState { unknown, healthy, caution, low };

// Timing has no dependency on Arduino, BLE, CTA or wall-clock time.
class ArrivalScreenState {
public:
  static constexpr uint32_t ArrivalPageIntervalMs = 6000;
  static constexpr uint32_t FirstArrivalPageIntervalMs = 8000;
  void setBoard(const ArrivalBoard& board, uint32_t now) {
    const std::string oldDirection = data.platforms[platform].direction;
    const std::string oldStation = data.platforms[platform].stationName;
    data = board;
    platform = 0;
    for (size_t i = 0; i < data.platformCount; ++i)
      if (data.platforms[i].direction == oldDirection && data.platforms[i].stationName == oldStation) platform = i;
    const bool samePlatform = hasData && current().direction == oldDirection && current().stationName == oldStation;
    if (!samePlatform || page >= pageCount()) { page = 0; pageStarted = now; }
    received = now; hasData = true;
  }
  void nextPlatform(uint32_t now) {
    if (!data.platformCount) return;
    const auto station = current().stationName;
    for (size_t offset = 1; offset <= data.platformCount; ++offset) {
      const size_t candidate = (platform + offset) % data.platformCount;
      if (data.platforms[candidate].stationName == station) { platform = candidate; break; }
    }
    page = 0; pageStarted = now;
  }
  void nextStation(uint32_t now) {
    if (!data.platformCount) return;
    const auto station = current().stationName;
    const auto direction = current().direction;
    for (size_t offset = 1; offset < data.platformCount; ++offset) {
      const size_t candidate = (platform + offset) % data.platformCount;
      if (data.platforms[candidate].stationName == station) continue;
      platform = candidate;
      // Keep the same displayed direction when the next station offers it.
      for (size_t i = 0; i < data.platformCount; ++i)
        if (data.platforms[i].stationName == data.platforms[candidate].stationName &&
            data.platforms[i].direction == direction) { platform = i; break; }
      break;
    }
    page = 0; pageStarted = now;
  }
  bool compact = false;
  size_t arrivalsPerPage() const { return compact ? 6 : 3; }
  size_t pageCount() const { return std::max(size_t(1), (std::min(size_t(9), current().arrivalCount) + arrivalsPerPage()-1) / arrivalsPerPage()); }
  uint32_t pageIntervalMs() const { return page==0 ? FirstArrivalPageIntervalMs : ArrivalPageIntervalMs; }
  bool tick(uint32_t now) {
    bool changed = false;
    const size_t count=pageCount();
    if (count > 1 && uint32_t(now - pageStarted) >= pageIntervalMs()) {
      // Skip complete cycles after a delayed tick, then advance at most one
      // cycle using each page's own dwell time. Page 1 gets 8 seconds every lap.
      const uint32_t cycle=FirstArrivalPageIntervalMs+uint32_t(count-1)*ArrivalPageIntervalMs;
      pageStarted += (uint32_t(now-pageStarted)/cycle)*cycle;
      while(uint32_t(now-pageStarted)>=pageIntervalMs()) {
        pageStarted += pageIntervalMs();
        page=(page+1)%count;
        changed=true;
      }
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

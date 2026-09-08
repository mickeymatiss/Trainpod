#pragma once
#include "ArrivalDisplay.h"
#include <vector>
#include <cstdlib>

enum class ArrivalPayloadResult { invalid, unavailable, valid };

// Versioned text adapter. Only normalized data reaches ArrivalScreen.
inline ArrivalPayloadResult decodeArrivalPayload(const std::string& text, ArrivalBoard& output) {
  if (text == "TP2\n!\n" || text == "Trains unavailable|Please try again||Refresh to retry|") return ArrivalPayloadResult::unavailable;
  if (text.size() > 2048 || text.find('\0') != std::string::npos || text.compare(0, 4, "TP2\n") != 0 || text.back() != '\n') return ArrivalPayloadResult::invalid;
  auto split = [](const std::string& input, char separator) {
    std::vector<std::string> result;
    size_t start = 0, end;
    while ((end = input.find(separator, start)) != std::string::npos) {
      result.push_back(input.substr(start, end-start)); start = end+1;
    }
    result.push_back(input.substr(start));
    return result;
  };
  const auto lines = split(text, '\n');
  if (lines.size() < 4 || lines[1].empty() || lines[1].size() > 48) return ArrivalPayloadResult::invalid;
  ArrivalBoard candidate;
  for (size_t i = 2; i + 1 < lines.size(); ++i) {
    const auto fields = split(lines[i], '\t');
    if (fields.size() == 2 && fields[0] == "P") {
      if (candidate.platformCount == candidate.platforms.size() || fields[1].empty() || fields[1].size() > 16) return ArrivalPayloadResult::invalid;
      auto& platform = candidate.platforms[candidate.platformCount++];
      platform.stationName = lines[1]; platform.direction = fields[1];
    } else if (fields.size() == 5 && fields[0] == "A" && candidate.platformCount) {
      auto& platform = candidate.platforms[candidate.platformCount-1];
      if (platform.arrivalCount == 9 || fields[1].empty() || fields[1].size() > 20 || fields[2].size() != 6 || fields[3].size() > 48 || fields[4].empty() || fields[4].size() > 4) return ArrivalPayloadResult::invalid;
      for (char c : fields[2]) if (!((c >= '0' && c <= '9') || (c >= 'A' && c <= 'F') || (c >= 'a' && c <= 'f'))) return ArrivalPayloadResult::invalid;
      for (char c : fields[4]) if (c < '0' || c > '9') return ArrivalPayloadResult::invalid;
      auto& arrival = platform.arrivals[platform.arrivalCount++];
      arrival = {fields[1], static_cast<uint32_t>(std::strtoul(fields[2].c_str(), nullptr, 16)), fields[3], std::atoi(fields[4].c_str())};
    } else return ArrivalPayloadResult::invalid;
  }
  if (!candidate.platformCount) return ArrivalPayloadResult::invalid;
  for (size_t i=0; i<candidate.platformCount; ++i) {
    auto& platform = candidate.platforms[i];
    std::stable_sort(platform.arrivals.begin(), platform.arrivals.begin()+platform.arrivalCount,
      [](const ArrivalDisplay& a, const ArrivalDisplay& b) { return a.eta < b.eta; });
  }
  output = candidate;
  return ArrivalPayloadResult::valid;
}

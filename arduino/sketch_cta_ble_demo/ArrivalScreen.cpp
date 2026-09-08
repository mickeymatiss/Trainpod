#include "ArrivalScreen.h"
#include "ArrivalSans.h"
#include "ArrivalSansBold.h"

namespace {
constexpr uint16_t BG = 0x0000, FG = 0xef7d, SECONDARY = 0xad55, QUIET = 0x528a;
constexpr uint16_t GREEN = 0x4e69, YELLOW = 0xfe60, RED = 0xf986;
}

void ArrivalScreen::begin(uint32_t now) { state.clockAdvanced = now; draw(now); }
void ArrivalScreen::setPlatforms(const ArrivalBoard& data, uint32_t now) { state.setBoard(data, now); dirty = true; }
void ArrivalScreen::nextPlatform(uint32_t now) { state.nextPlatform(now); dirty = true; }
void ArrivalScreen::setConnected(bool value) { if (connected != value) { connected = value; dirty = true; } }
void ArrivalScreen::setBatteryPercent(int percent) {
  const auto value = percent < 0 ? BatteryState::unknown : percent <= LOW_BATTERY ? BatteryState::low : percent <= CAUTION_BATTERY ? BatteryState::caution : BatteryState::healthy;
  if (battery != value) { battery = value; dirty = true; }
}
void ArrivalScreen::tick(uint32_t now) { if (state.tick(now)) dirty = true; if (dirty) draw(now); }

void ArrivalScreen::text(const std::string& value, int x, int baseline, int width, uint16_t color, bool bold, bool right) {
  gfx.setFont(bold ? &FreeSansBold9pt7b : &FreeSans9pt7b);
  gfx.setTextSize(1); gfx.setTextWrap(false); gfx.setTextColor(color);
  // The bundled font is ASCII. Transliteration happens in the iOS adapter.
  String fitted(value.c_str());
  int16_t bx, by; uint16_t w, h;
  gfx.getTextBounds(fitted, 0, baseline, &bx, &by, &w, &h);
  if (w > width) {
    while (fitted.length()) {
      fitted.remove(fitted.length() - 1);
      gfx.getTextBounds(fitted + "...", 0, baseline, &bx, &by, &w, &h);
      if (w <= width) break;
    }
    fitted += "...";
  }
  gfx.getTextBounds(fitted, 0, baseline, &bx, &by, &w, &h);
  gfx.setCursor((right ? x + width - w : x) - bx, baseline);
  gfx.print(fitted);
}

void ArrivalScreen::draw(uint32_t now) {
  dirty = false;
  const int width = gfx.width(), height = gfx.height();
  const int padding = 8, footer = height - 12;
  gfx.fillScreen(BG);
  const auto& platform = state.current();
  text(platform.direction, padding, 23, 85, SECONDARY, false);
  text(platform.stationName, 101, 23, width - 109, FG, true, true);
  gfx.drawFastHLine(padding, 32, width - padding * 2, QUIET);
  gfx.fillRect(padding, 31, 28, 3, FG);
  // Three fixed slots, including when empty. Middle region absorbs panel width.
  const int rowHeight = (height - 60) / 3;
  for (size_t slot = 0; slot < 3; ++slot) {
    const size_t index = state.page * 3 + slot;
    if (index >= platform.arrivalCount) continue;
    const auto& arrival = platform.arrivals[index];
    const int baseline = 53 + slot * rowHeight;
    const uint32_t rgb = arrival.routeColor;
    text(arrival.routeLabel, padding, baseline, 61, RGB565(rgb >> 16, (rgb >> 8) & 255, rgb & 255), false);
    text(arrival.destination, 77, baseline, width - 77 - 82, SECONDARY, false);
    text(std::to_string(arrival.eta) + " min", width - 78, baseline, 70, FG, true, true);
  }
  gfx.fillCircle(11, footer, 3, connected ? GREEN : QUIET);
  const uint16_t batteryColor = battery == BatteryState::healthy ? GREEN : battery == BatteryState::caution ? YELLOW : battery == BatteryState::low ? RED : QUIET;
  gfx.fillTriangle(29, footer-6, 23, footer+1, 28, footer+1, batteryColor);
  gfx.fillTriangle(26, footer-1, 31, footer-1, 25, footer+6, batteryColor);
  gfx.drawCircle(45, footer, 5, SECONDARY);
  const int dx[] = {0, 3, 0, -3}, dy[] = {-3, 0, 3, 0};
  gfx.drawLine(45, footer, 45 + dx[state.clockFrame], footer + dy[state.clockFrame], SECONDARY);
  if (state.ageMinutes(now) >= 2) {
    gfx.setFont(nullptr); gfx.setTextSize(1); gfx.setTextColor(SECONDARY);
    gfx.setCursor(55, footer - 3); gfx.print(state.ageMinutes(now)); gfx.print("m");
  }
  if (state.pageCount() > 1) for (size_t page = 0; page < state.pageCount(); ++page) {
    const int x = width - 12 - (state.pageCount() - 1 - page) * 13;
    if (page == state.page) {
      gfx.fillTriangle(x, footer-4, x+4, footer, x, footer+4, FG);
      gfx.fillTriangle(x, footer-4, x-4, footer, x, footer+4, FG);
    } else {
      gfx.drawLine(x, footer-4, x+4, footer, QUIET); gfx.drawLine(x+4, footer, x, footer+4, QUIET);
      gfx.drawLine(x, footer+4, x-4, footer, QUIET); gfx.drawLine(x-4, footer, x, footer-4, QUIET);
    }
  }
}

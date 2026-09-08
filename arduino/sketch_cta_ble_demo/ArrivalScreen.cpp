#include "ArrivalScreen.h"
#include "DepartureMono11.h"

namespace {
constexpr uint16_t BG = RGB565(0xdf, 0xcc, 0xa7), FG = RGB565(0x00, 0x00, 0x00);
constexpr uint16_t SECONDARY = RGB565(0x00, 0x00, 0x00);
constexpr uint16_t DIVIDER = RGB565(0xb3, 0x9f, 0x7d);
constexpr uint16_t CTA_GREEN = RGB565(0x4f, 0x8b, 0x5b), CTA_PINK = RGB565(0xd8, 0x5c, 0x88);
uint16_t routeColor(const ArrivalDisplay& arrival) {
  // Presentation overrides only; keep the incoming board and other routes intact.
  if (arrival.routeLabel == "Green") return CTA_GREEN;
  if (arrival.routeLabel == "Pink") return CTA_PINK;
  const uint32_t rgb = arrival.routeColor;
  return RGB565((rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255);
}
}

void ArrivalScreen::begin(uint32_t now) { state.clockAdvanced = now; connectionAttemptStarted = now; draw(now); }
void ArrivalScreen::setPlatforms(const ArrivalBoard& data, uint32_t now) { state.setBoard(data, now); dirty = true; }
void ArrivalScreen::nextPlatform(uint32_t now) { state.nextPlatform(now); dirty = true; }
void ArrivalScreen::setConnected(bool value) {
  if (connected == value) return;
  connected = value;
  connectionFailed = false;
  restartConnectionTimer = !value;
  dirty = true;
}
void ArrivalScreen::setBatteryPercent(int percent) {
  const auto value = percent < 0 ? BatteryState::unknown : percent < LOW_BATTERY ? BatteryState::low : percent <= CAUTION_BATTERY ? BatteryState::caution : BatteryState::healthy;
  if (battery != value) { battery = value; dirty = true; }
}
void ArrivalScreen::tick(uint32_t now) {
  if (suspended) return;
  if (restartConnectionTimer) { connectionAttemptStarted = now; restartConnectionTimer = false; }
  const bool failed = !connected && uint32_t(now - connectionAttemptStarted) >= CONNECTION_WARNING_MS;
  if (connectionFailed != failed) { connectionFailed = failed; dirty = true; }
  if (state.tick(now)) dirty = true;
  if (dirty) draw(now);
}

void ArrivalScreen::suspend(uint32_t now) {
  if (suspended) return;
  suspended = true;
  suspendedAt = now;
}

void ArrivalScreen::resume(uint32_t now) {
  if (!suspended) return;
  const uint32_t elapsed = now - suspendedAt;
  // Freeze pagination and animation, not train freshness or BLE readiness age.
  state.pageStarted += elapsed;
  state.clockAdvanced += elapsed;
  suspended = false;
  dirty = true;
  tick(now); // Show the saved platform/page immediately, without waiting for data.
}

void ArrivalScreen::text(const std::string& value, int x, int baseline, int width, uint16_t color, uint8_t scale, bool right) {
  gfx.setFont(&DepartureMono11);
  gfx.setTextSize(scale); gfx.setTextWrap(false); gfx.setTextColor(color);
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
  text(platform.direction, padding, 23, 85, SECONDARY);
  text(platform.stationName, 101, 23, width - 109, FG, 2, true);
  gfx.drawFastHLine(padding, 31, width - padding * 2, DIVIDER);
  // 40px pitch on the 320x172 panel: four more pixels between fixed slots.
  const int rowHeight = (height - 52) / 3;
  for (size_t slot = 0; slot < 3; ++slot) {
    const size_t index = state.page * 3 + slot;
    if (index >= platform.arrivalCount) continue;
    const auto& arrival = platform.arrivals[index];
    const int baseline = 60 + slot * rowHeight;
    const std::string eta = std::to_string(arrival.eta);
    // Departure's 11px grid enlarged by exact integer factors, never smoothed.
    text(eta, padding, baseline + 4, 54, FG, eta.size() > 3 ? 2 : 3, true);
    text(arrival.routeLabel, 68, baseline, 84, routeColor(arrival), 2);
    text(std::string(1, char(0x7f)), 159, baseline, 7, SECONDARY); // Actual Departure Mono right arrow.
    text(arrival.destination, 174, baseline, width - 174 - padding, SECONDARY);
  }
  // Contextual footer: healthy BLE, fresh data and healthy/unknown battery are silent.
  int statusX = padding;
  if (!connected) {
    if (connectionFailed) {
      text("BLE!", statusX, footer + 4, 32, FG);
      statusX += 40;
    } else {
      gfx.fillCircle(statusX + 3, footer, 2, SECONDARY);
      statusX += 14;
    }
  }
  if (battery == BatteryState::caution || battery == BatteryState::low) {
    const uint16_t color = battery == BatteryState::low ? FG : SECONDARY;
    gfx.drawRect(statusX, footer - 4, 12, 8, color);
    gfx.drawFastVLine(statusX + 12, footer - 2, 4, color);
    gfx.fillRect(statusX + 2, footer - 2, battery == BatteryState::low ? 2 : 5, 4, color);
    statusX += 22;
  }
  const uint32_t age = state.ageMinutes(now);
  if (state.hasData && age >= STALE_DISPLAY_MINUTES) {
    const bool warning = age >= STALE_WARNING_MINUTES;
    text(std::to_string(age) + "m old" + (warning ? "!" : ""), statusX, footer + 4,
      width - statusX - 54, warning ? FG : SECONDARY);
  }
  // One outlined diamond even on a single page; multiple pages retain selection.
  for (size_t page = 0; page < state.pageCount(); ++page) {
    const int x = width - 12 - (state.pageCount() - 1 - page) * 13;
    if (state.pageCount() > 1 && page == state.page) {
      gfx.fillTriangle(x, footer-3, x+3, footer, x, footer+3, SECONDARY);
      gfx.fillTriangle(x, footer-3, x-3, footer, x, footer+3, SECONDARY);
    } else {
      gfx.drawLine(x, footer-3, x+3, footer, SECONDARY); gfx.drawLine(x+3, footer, x, footer+3, SECONDARY);
      gfx.drawLine(x, footer+3, x-3, footer, SECONDARY); gfx.drawLine(x-3, footer, x, footer-3, SECONDARY);
    }
  }
}

#pragma once

#include <Arduino_GFX_Library.h>
#include "src/products/transit/data/ArrivalDisplay.h"

// Central display palette. BLE and NVS use RGB888; rendering uses RGB565.
class pallete {
public:
  static constexpr uint32_t DEFAULT_UI_COLOR = 0xD6CCBB;
  static void begin();
  // RGB888 order matches the app and the version-1 BLE theme protocol.
  enum Role { Background, PrimaryText, Detail, SecondaryText, ArrivalBadge, ArrivalBadgeText, RoleCount };
  struct Theme { uint32_t rgb[RoleCount]; };
  static bool storeTheme(const Theme& theme);
  static bool valid(const Theme& theme);
  static uint32_t fingerprint(const Theme& theme);
  static const Theme& theme() { return activeTheme; }
  static bool storeUiColor(uint32_t rgb);
  static uint32_t uiColor() { return activeTheme.rgb[Background]; }
  static uint16_t color(Role role) {
    const uint32_t rgb = activeTheme.rgb[role];
    return RGB565((rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255);
  }
  static uint16_t background() { return color(Background); }
  static uint16_t primaryText() { return color(PrimaryText); }
  static uint16_t detail() { return color(Detail); }
  static uint16_t secondaryText() { return color(SecondaryText); }
  static uint16_t arrivalBadge() { return color(ArrivalBadge); }
  static uint16_t arrivalBadgeText(uint8_t opacity);

  // Startup animation colors, already encoded as RGB565.
  static constexpr uint16_t SWAMP_GREEN[5] = {
    0x5B8B, 0x6C0D, 0x746E, 0x84D0, 0x9532
  };

  static constexpr uint16_t SAPPHIRE[5] = {
    0x1231, 0x1273, 0x1AB5, 0x3356, 0x4BD7
  };

  static constexpr uint16_t BACKGROUND_COLOR = 0x0000;
  static constexpr uint16_t MONOGRAM_COLOR = 0xFFFE;

  static uint16_t routeColor(const ArrivalDisplay& arrival) {
    // Route identity comes only from transit data, never from the theme.
    const uint32_t rgb = arrival.routeColor;
    return RGB565((rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255);
  }

private:
  static Theme activeTheme;
  pallete() = delete;
};

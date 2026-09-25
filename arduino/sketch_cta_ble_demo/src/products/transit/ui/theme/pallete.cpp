#include "pallete.h"
#include <Preferences.h>

constexpr uint16_t pallete::SWAMP_GREEN[5];
constexpr uint16_t pallete::SAPPHIRE[5];
namespace {
// Exact RGB888 factory palette; matches DeviceTheme.defaultTheme in iOS.
// A valid user-saved theme continues to take precedence at startup.
const pallete::Theme factoryTheme = {{pallete::DEFAULT_UI_COLOR, 0x19005D,
  0xF70000, 0x000123, 0x000000, 0xFFB485}};
struct StoredTheme { uint32_t version; pallete::Theme theme; };
static_assert(sizeof(StoredTheme) == 28, "Stable theme storage layout");
}
pallete::Theme pallete::activeTheme = factoryTheme;
pallete::Theme pallete::renderTheme = factoryTheme;

bool pallete::valid(const Theme& theme) {
  for (uint32_t rgb : theme.rgb) if (rgb > 0xFFFFFF) return false;
  return true;
}

uint32_t pallete::fingerprint(const Theme& theme) {
  uint32_t hash = 2166136261u;
  for (uint32_t rgb : theme.rgb)
    for (int shift = 16; shift >= 0; shift -= 8) {
      hash ^= (rgb >> shift) & 255;
      hash *= 16777619u;
    }
  return hash;
}

void pallete::begin() {
  activeTheme = factoryTheme;
  Preferences preferences;
  if (!preferences.begin("ui", true)) return;
  if (preferences.isKey("theme")) {
    StoredTheme stored{};
    if (preferences.getType("theme") == PT_BLOB &&
        preferences.getBytesLength("theme") == sizeof(stored) &&
        preferences.getBytes("theme", &stored, sizeof(stored)) == sizeof(stored) &&
        stored.version == 1 && valid(stored.theme)) activeTheme = stored.theme;
    // A corrupt theme falls back to factory, not an obsolete background key.
  } else if (preferences.isKey("color") && preferences.getType("color") == PT_U32) {
    const uint32_t legacy = preferences.getUInt("color", 0xFFFFFFFF);
    if (legacy <= 0xFFFFFF) activeTheme.rgb[Background] = legacy;
  }
  preferences.end();
}

bool pallete::storeTheme(const Theme& theme) {
  if (!valid(theme)) return false;
  Preferences preferences;
  if (!preferences.begin("ui", false)) return false;
  const StoredTheme stored{1, theme};
  // One committed blob prevents partially saved palettes after power loss.
  const bool saved = preferences.putBytes("theme", &stored, sizeof(stored)) == sizeof(stored);
  preferences.end();
  if (saved) activeTheme = theme;
  return saved;
}

bool pallete::storeUiColor(uint32_t rgb) {
  Theme next = activeTheme;
  next.rgb[Background] = rgb;
  return storeTheme(next);
}

uint16_t pallete::arrivalBadgeText(uint8_t opacity) {
  const uint32_t fg = renderTheme.rgb[ArrivalBadgeText], bg = renderTheme.rgb[ArrivalBadge];
  const auto channel = [=](int shift) {
    return (((fg >> shift) & 255) * opacity + ((bg >> shift) & 255) * (255-opacity) + 127) / 255;
  };
  return RGB565(channel(16), channel(8), channel(0));
}

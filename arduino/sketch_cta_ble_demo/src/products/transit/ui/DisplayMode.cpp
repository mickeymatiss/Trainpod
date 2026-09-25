#include "DisplayMode.h"
#include <Preferences.h>
#include "../../../platform/diagnostics/SerialLog.h"

namespace { bool compactMode=false; }
void DisplayMode::begin() {
  compactMode=false;
  Preferences preferences;
  if(preferences.begin("ui",true)) {
    compactMode=preferences.getUChar("viewMode",0)==1;
    preferences.end();
  }
  InfoLog.printf("[UI] Display mode: %s\n",compactMode ? "compact" : "standard");
}
bool DisplayMode::compact() { return compactMode; }
bool DisplayMode::store(bool compact) {
  if(compact==compactMode) return true;
  Preferences preferences;
  if(!preferences.begin("ui",false)) return false;
  const bool saved=preferences.putUChar("viewMode",compact ? 1 : 0)==1;
  preferences.end();
  if(saved) {
    compactMode=compact;
    InfoLog.printf("[UI] Display mode saved: %s\n",compact ? "compact" : "standard");
  }
  return saved;
}

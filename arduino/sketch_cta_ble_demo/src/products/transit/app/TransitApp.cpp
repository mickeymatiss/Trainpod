#include <Arduino_GFX_Library.h>
#include "../ble/BleIntegration.h"
#include "../ui/ArrivalScreen.h"
#include "../ui/theme/pallete.h"
#include "../data/ArrivalPayload.h"
#include "../input/ButtonTap.h"
#include "../../../platform/power/PowerLifecycle.h"
#include "../../../platform/power/BacklightFade.h"
#include "../../../platform/diagnostics/DiagnosticStore.h"
#include "../../../platform/metrics/MetricsStore.h"
#include "../../../platform/power/PerformanceMode.h"
#include <esp_timer.h>

#include "../../../platform/device/DeviceHardware.h"
Arduino_GFX* gfx = deviceDisplay();
BacklightFade backlight(LCD_BL);
ArrivalScreen arrivalScreen(*gfx);
bool displayReady = false;
int lastButtonReading = HIGH, buttonState = HIGH;
uint32_t lastButtonChangeMs = 0;
ButtonTap navigationTaps;
constexpr uint32_t BLE_HOLD_MS = 2000;
uint32_t buttonPressedMs = 0;
bool holdArmed = false, holdTriggered = false, tapEligible = false;

void navigate(ButtonTap::Action action, uint32_t now) {
  if (action == ButtonTap::Action::Platform) {
    Serial.println("[UI] Single tap: next platform");
    arrivalScreen.nextPlatform(now);
  } else if (action == ButtonTap::Action::Station) {
    Serial.println("[UI] Double tap: next station");
    arrivalScreen.nextStation(now);
  }
}

void powerStateChanged(PowerState previous, PowerState next, uint32_t now);
PowerLifecycle powerLifecycle(powerStateChanged);

// All backlight/standby side effects pass through this one transition handler.
void powerStateChanged(PowerState previous, PowerState next, uint32_t now) {
  DiagnosticStore::shared().event(next == PowerState::ACTIVE ? EventCode::POWER_ACTIVE : next == PowerState::DIMMED ? EventCode::POWER_DIMMED : EventCode::POWER_STANDBY);
  switch (next) {
    case PowerState::ACTIVE:
      if (previous == PowerState::SCREEN_OFF_STANDBY) {
        Serial.println("[POWER] SCREEN_OFF_STANDBY -> ACTIVE; restoring cached UI");
        arrivalScreen.setConnected(bleIsReady());
        if (displayReady) arrivalScreen.resume(now);
        backlight.fadeTo(PowerConfig::ACTIVE_BRIGHTNESS, millis(), PowerConfig::BACKLIGHT_FADE_MS);
        // Requests run in the normal BLE poll, after the old board is visible.
        setTransitRefreshPaused(false);
      } else {
        backlight.fadeTo(PowerConfig::ACTIVE_BRIGHTNESS, millis(), PowerConfig::BACKLIGHT_FADE_MS);
        Serial.println(previous == PowerState::DIMMED ? "[POWER] DIMMED -> ACTIVE" : "[POWER] State: ACTIVE");
      }
      break;
    case PowerState::DIMMED:
      navigationTaps.reset();
      backlight.fadeTo(PowerConfig::DIM_BRIGHTNESS, millis(), PowerConfig::BACKLIGHT_FADE_MS);
      Serial.println("[POWER] Inactivity timeout: ACTIVE -> DIMMED");
      break;
    case PowerState::SCREEN_OFF_STANDBY:
      navigationTaps.reset();
      setTransitRefreshPaused(true);
      arrivalScreen.suspend(now);
      backlight.fadeTo(0, millis(), PowerConfig::BACKLIGHT_FADE_MS);
      MetricsStore::shared().recordBootDataFailure(); // No-op after a startup outcome.
      MetricsStore::shared().flush(); // Save short sessions; no BLE mutex is held.
      DiagnosticStore::shared().flush();
      Serial.println("[POWER] DIMMED -> SCREEN_OFF_STANDBY; CPU awake, BLE OFF");
      break;
  }
}

// Preserve cached arrivals and their timestamp while refreshing.
void beginRefreshDisplay() {}

void uiColorChanged() {
  if (displayReady) arrivalScreen.themeChanged(millis());
}

void setupTransitApp() {
  setPerformanceMode(PerformanceMode::ACTIVE);
  Serial.begin(115200);
  MetricsStore::shared().begin();
  DiagnosticStore::shared().begin();
  pallete::begin();
  backlight.begin();
  pinMode(BUTTON_PIN, INPUT_PULLUP);
  lastButtonReading = buttonState = digitalRead(BUTTON_PIN);
  lastButtonChangeMs = millis();
  displayReady = gfx->begin();
  if (displayReady) {
    gfx->setRotation(1); // Existing physical panel: 320 x 172.
    arrivalScreen.begin(millis());
    arrivalScreen.setBatteryPercent(-1); // No battery ADC configured on this prototype.
  } else {
    DiagnosticStore::shared().event(EventCode::ERROR_GENERIC,LogLevel::Error,100);
    Serial.println("LCD init failed");
  }
  setupBleIntegration(beginRefreshDisplay, uiColorChanged);
  powerLifecycle.begin(millis());
  DiagnosticStore::shared().event(EventCode::BOOT_READY);
}

void loopTransitApp() {
  const uint32_t now = millis();
  // Debounce once, before inactivity processing: a real press wins at a timeout.
  const int reading = digitalRead(BUTTON_PIN);
  if (reading != lastButtonReading) lastButtonChangeMs = now;
  if (uint32_t(now-lastButtonChangeMs) >= PowerConfig::BUTTON_DEBOUNCE_MS && reading != buttonState) {
    buttonState = reading;
    if (buttonState == LOW) {
      MetricsStore::shared().recordButtonPress();
      DiagnosticStore::shared().event(EventCode::BUTTON_PRESSED,LogLevel::Info);
      const auto action = powerLifecycle.buttonPressed(now);
      buttonPressedMs = now;
      holdArmed = true;
      holdTriggered = false;
      tapEligible = action == PowerButtonAction::NAVIGATE && !bleWakeTestEnabled();
      if (!tapEligible) navigationTaps.reset();
      if (action == PowerButtonAction::WAKE_ONLY)
        Serial.println("[POWER] Wake-only button press consumed");
    } else {
      // Commit only short, eligible taps. A hold never also navigates.
      if (holdArmed && !holdTriggered && tapEligible && !bleWakeTestEnabled() &&
          uint32_t(now-buttonPressedMs) < BLE_HOLD_MS)
        navigate(navigationTaps.press(now), now);
      holdArmed = false;
      tapEligible = false;
    }
  }
  if (buttonState == LOW && reading == LOW && holdArmed && !holdTriggered &&
      uint32_t(now-buttonPressedMs) >= BLE_HOLD_MS) {
    holdTriggered = true;
    navigationTaps.reset();
    openBleManualWindow();
  }
  lastButtonReading = reading;
  powerLifecycle.tick(now);
  if (powerLifecycle.state() != PowerState::ACTIVE || bleWakeTestEnabled()) navigationTaps.reset();
  else if (buttonState == HIGH) navigate(navigationTaps.tick(now), now);

  // Normal BLE sessions close in standby; an explicit button window may finish there.
  if (Serial.available()) setPerformanceMode(PerformanceMode::ACTIVE);
  pollBleIntegration();
  MetricsStore::shared().tick(millis()); // Still flush periodically in screen-off standby.
  DiagnosticStore::shared().tick(millis());
  backlight.update(millis()); // Continue fading even while rendering is suspended.
  if (powerLifecycle.isStandby()) {
    setPerformanceMode(PerformanceMode::IDLE);
    return;
  }

  arrivalScreen.setConnected(bleIsReady());
  String payload;
  uint64_t transactionId=0;
  if (takeTransitPayload(payload,transactionId)) {
    setPerformanceMode(PerformanceMode::ACTIVE);
    DiagnosticStore::shared().event(EventCode::PAYLOAD_PARSE_STARTED,LogLevel::Info,payload.length(),0,transactionId);
    ArrivalBoard board;
    const auto result = decodeArrivalPayload(std::string(payload.c_str(), payload.length()), board);
    if (result == ArrivalPayloadResult::valid) {
      DiagnosticStore::shared().event(EventCode::PAYLOAD_PARSE_SUCCESS,LogLevel::Info,0,0,transactionId);
      arrivalScreen.setPlatforms(board, now);
      arrivalScreen.setDisplayTransaction(transactionId);
      DiagnosticStore::shared().event(EventCode::DATA_APPLIED,LogLevel::Info,payload.length(),0,transactionId);
      acknowledgeTransitApplied(transactionId,payload.length());
      finishTransitRefresh(true);
      DiagnosticStore::shared().event(EventCode::FETCH_SUCCESS,LogLevel::Info,0,0,transactionId);
      Serial.println("[DISPLAY] Arrival board accepted");
      Serial.printf("[BLE] Received platformCount=%u\n", unsigned(board.platformCount));
    } else {
      MetricsStore::shared().recordBootDataFailure();
      const uint8_t parseError=result==ArrivalPayloadResult::unavailable ? 2 : 1;
      DiagnosticStore::shared().event(EventCode::PAYLOAD_PARSE_FAILURE,LogLevel::Warn,parseError,0,transactionId);
      rejectTransitPayload(transactionId,parseError,payload.length());
      finishTransitRefresh(false);
      if (result == ArrivalPayloadResult::unavailable) {
        DiagnosticStore::shared().event(EventCode::FETCH_FAILURE,LogLevel::Warn,0,0,transactionId);
      } else {
        DiagnosticStore::shared().count(DiagnosticCounter::InvalidPayload);

      }
      Serial.println(result == ArrivalPayloadResult::unavailable ? "[DISPLAY] Unavailable; retaining cached arrivals" : "[DISPLAY] Invalid payload; retaining cached arrivals");
    }
  }
  if (takeTransitRefreshFailure()) {
    MetricsStore::shared().recordBootDataFailure();
    Serial.println("[DISPLAY] Refresh failed; retaining cached arrivals");
  }
  if (displayReady) arrivalScreen.tick(now);
  // Parsing, rendering and flash writes are complete; live BLE prevents IDLE.
  setPerformanceMode(PerformanceMode::IDLE);
}

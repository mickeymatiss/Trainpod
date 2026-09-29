#include "../../../platform/diagnostics/SerialLog.h"
#include "../../../platform/device/DeviceIdentity.h"
#include "../../../platform/setup/DeviceProvisioning.h"
#include "../ble/BleIntegration.h"
#include "../ui/DisplayController.h"
#include "../ui/theme/pallete.h"
#include "../ui/DisplayMode.h"
#include "../data/ArrivalPayload.h"
#include "../input/ButtonTap.h"
#include "../../../platform/power/PowerLifecycle.h"
#include "../../../platform/power/BacklightFade.h"
#include "../../../platform/power/NightBrightness.h"
#include "../../../platform/diagnostics/DiagnosticStore.h"
#include "../../../platform/metrics/MetricsStore.h"
#include "../../../platform/power/PerformanceMode.h"
#include <esp_timer.h>
#include "../calibration/ColorCalibration.h"

#include "../../../platform/device/DeviceHardware.h"
BacklightFade backlight(LCD_BL);
bool screenDarkLogged = false;
bool showingSetup=false;
void drawSetup() { DisplayController::setSetupState(DeviceProvisioning::shared().state()); }
bool handleUiSerialCommand(const char* command) {
  if(ColorCalibration::command(command)) return true;
  if(NightBrightness::shared().command(command)) return true;
  return DisplayController::command(command);
}
int lastButtonReading = HIGH, buttonState = HIGH;
uint32_t lastButtonChangeMs = 0;
ButtonTap navigationTaps;
constexpr uint32_t BLE_HOLD_MS = 2000;
uint32_t buttonPressedMs = 0;
bool holdArmed = false, holdTriggered = false, tapEligible = false;

void navigate(ButtonTap::Action action, uint32_t now) {
  if (action == ButtonTap::Action::Platform) {
    DebugLog.println("[UI] Single tap: next platform");
    DisplayController::nextPlatform(now);
  } else if (action == ButtonTap::Action::Station) {
    DebugLog.println("[UI] Double tap: next station");
    DisplayController::nextStation(now);
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
        DebugLog.println("[POWER] SCREEN_OFF_STANDBY -> ACTIVE; restoring cached UI");
        DisplayController::setConnected(bleIsReady());
        DisplayController::resume(now);
        backlight.fadeTo(NightBrightness::shared().activeLevel(), millis(), PowerConfig::BACKLIGHT_FADE_MS);
        // Resume the normal request pipeline without waiting for the display.
        setTransitRefreshPaused(false);
      } else {
        backlight.fadeTo(NightBrightness::shared().activeLevel(), millis(), PowerConfig::BACKLIGHT_FADE_MS);
        DebugLog.println(previous == PowerState::DIMMED ? "[POWER] DIMMED -> ACTIVE" : "[POWER] State: ACTIVE");
      }
      break;
    case PowerState::DIMMED:
      navigationTaps.reset();
      backlight.fadeTo(std::min(PowerConfig::DIM_BRIGHTNESS,NightBrightness::shared().activeLevel()), millis(), PowerConfig::BACKLIGHT_FADE_MS);
      DebugLog.println("[POWER] Inactivity timeout: ACTIVE -> DIMMED");
      break;
    case PowerState::SCREEN_OFF_STANDBY:
      navigationTaps.reset();
      setTransitRefreshPaused(true);
      DisplayController::suspend(now);
      backlight.fadeTo(0, millis(), PowerConfig::BACKLIGHT_FADE_MS);
      MetricsStore::shared().recordBootDataFailure(); // No-op after a startup outcome.
      MetricsStore::shared().flush(); // Save short sessions; no BLE mutex is held.
      DiagnosticStore::shared().flush();
      DebugLog.println("[POWER] DIMMED -> SCREEN_OFF_STANDBY; CPU awake, transit paused");
      break;
  }
}

void uiColorChanged() {
  DisplayController::themeChanged(millis());
}

void setupTransitApp() {
  setPerformanceMode(PerformanceMode::ACTIVE);
  Serial.begin(115200);
#if ARDUINO_USB_CDC_ON_BOOT && ARDUINO_USB_MODE
  // A disconnected or backpressured USB host must never stall the app loop.
  Serial.setTxTimeoutMs(0);
#endif
  InfoLog.println("[BOOT] Serial initialized; loading identity");
  DeviceIdentity::begin();
  InfoLog.println("[BOOT] Identity ready; loading provisioning");
  DeviceProvisioning::shared().begin();
  showingSetup=!DeviceProvisioning::shared().provisioned();
  InfoLog.println("[BOOT] Provisioning ready; loading settings and diagnostics");
  MetricsStore::shared().begin();
  DiagnosticStore::shared().begin();
  pallete::begin();
  DisplayMode::begin();
  backlight.begin();
  ColorCalibration::begin(backlight);
  pinMode(BUTTON_PIN, INPUT_PULLUP);
  lastButtonReading = digitalRead(BUTTON_PIN);
  buttonState = HIGH; // A button held at boot still produces a debounced down edge.
  lastButtonChangeMs = millis();
  DisplayController::begin();
  if(showingSetup)drawSetup();
  InfoLog.println("[BOOT] App state ready; initializing BLE integration");
  setupBleIntegration(uiColorChanged);
  if(showingSetup)setTransitRefreshPaused(true);
  else { powerLifecycle.begin(millis());runTransitUpdate(TransitUpdateReason::STARTUP); }
  DiagnosticStore::shared().event(EventCode::BOOT_READY);
  InfoLog.println("[BOOT] Setup complete; entering main loop");
}

void loopTransitApp() {
  const uint32_t now = millis();
  if(ColorCalibration::active()) {
    pollBleIntegration();DisplayController::startRenderer();DisplayController::tick(millis());
    ColorCalibration::tick();delay(1);return;
  }
  static bool firstLoop=true;
  static uint32_t lastHeartbeat=0;
  if(firstLoop || uint32_t(now-lastHeartbeat)>=5000) {
    InfoLog.printf("[LOOP] alive uptime=%lums heap=%lu provisioned=%u\n",
      (unsigned long)now,(unsigned long)ESP.getFreeHeap(),DeviceProvisioning::shared().provisioned());
    firstLoop=false;lastHeartbeat=now;
  }
  DisplayController::tick(now);
  if(!DeviceProvisioning::shared().provisioned()) {
    showingSetup=true;
    // No transit refresh or normal power lifecycle owns setup availability.
    setTransitRefreshPaused(true);
    const int reading=digitalRead(BUTTON_PIN);
    if(reading!=lastButtonReading)lastButtonChangeMs=now;
    if(uint32_t(now-lastButtonChangeMs)>=PowerConfig::BUTTON_DEBOUNCE_MS && reading!=buttonState) {
      buttonState=reading;
      if(buttonState==LOW)DeviceProvisioning::shared().buttonPressed();
    }
    lastButtonReading=reading;
    pollBleIntegration(); // Runs setup queue and continuous-advertising watchdog.
    if(ColorCalibration::active()) { DisplayController::startRenderer();return; }
    DisplayController::startRenderer();
    drawSetup();
    DisplayController::tick(millis());
    backlight.fadeTo(NightBrightness::shared().activeLevel(),now,PowerConfig::BACKLIGHT_FADE_MS);
    backlight.update(now);
    return;
  }
  if(showingSetup) {
    showingSetup=false;holdArmed=false;holdTriggered=false;tapEligible=false;
    navigationTaps.reset();
    DisplayController::setSetupState(-1);
    setTransitRefreshPaused(false);powerLifecycle.begin(now);
    runTransitUpdate(TransitUpdateReason::STARTUP);
  }
  // Debounce once, before inactivity processing: a real press wins at a timeout.
  const int reading = digitalRead(BUTTON_PIN);
  if (reading != lastButtonReading) {
    lastButtonChangeMs = now;
  }
  if (uint32_t(now-lastButtonChangeMs) >= PowerConfig::BUTTON_DEBOUNCE_MS && reading != buttonState) {
    buttonState = reading;
    if (buttonState == LOW) {
      MetricsStore::shared().recordButtonPress();
      DiagnosticStore::shared().event(EventCode::BUTTON_PRESSED,LogLevel::Info);
      const auto action = powerLifecycle.buttonPressed(now);
      DisplayController::buttonChanged(true,now);
      buttonPressedMs = now;
      holdArmed = true;
      holdTriggered = false;
      tapEligible = action == PowerButtonAction::NAVIGATE && !bleWakeTestEnabled();
      if (!tapEligible) navigationTaps.reset();
      if (action == PowerButtonAction::WAKE_ONLY)
        DebugLog.println("[POWER] Wake-only button press consumed");
    } else {
      DisplayController::buttonChanged(false,now);
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
  // A physically held tab (or explicit serial hold) must remain visible.
  if(buttonState==LOW || DisplayController::feedbackHeld()) powerLifecycle.buttonPressed(now);
  powerLifecycle.tick(now);
  if (powerLifecycle.state() != PowerState::ACTIVE || bleWakeTestEnabled()) navigationTaps.reset();
  else if (buttonState == HIGH) navigate(navigationTaps.tick(now), now);

  // Normal BLE sessions close in standby; an explicit button window may finish there.
  if (Serial.available()) setPerformanceMode(PerformanceMode::ACTIVE);
  pollBleIntegration();
  if(ColorCalibration::active()) { DisplayController::startRenderer();return; }
  DisplayController::startRenderer(); // Only after BLE/serial have been serviced.
  MetricsStore::shared().tick(millis()); // Still flush periodically in screen-off standby.
  DiagnosticStore::shared().tick(millis());
  const uint8_t activeBrightness=NightBrightness::shared().activeLevel();
  const uint8_t targetBrightness=powerLifecycle.isStandby() ? 0 :
    powerLifecycle.state()==PowerState::DIMMED ? std::min(PowerConfig::DIM_BRIGHTNESS,activeBrightness) : activeBrightness;
  backlight.fadeTo(targetBrightness,millis(),PowerConfig::BACKLIGHT_FADE_MS);
  backlight.update(millis()); // Continue fading even while rendering is suspended.
  if(!powerLifecycle.isStandby()) screenDarkLogged=false;
  else if(backlight.isDark() && !screenDarkLogged) {
    InfoLog.println("Screen dark; standby (CPU awake)");
    screenDarkLogged=true;
  }
  if (powerLifecycle.isStandby()) {
    DisplayController::tick(millis());
    setPerformanceMode(PerformanceMode::IDLE);
    return;
  }

  DisplayController::setConnected(bleIsReady());
  String payload;
  uint64_t transactionId=0;
  if (takeTransitPayload(payload,transactionId)) {
    setPerformanceMode(PerformanceMode::ACTIVE);
    DiagnosticStore::shared().event(EventCode::PAYLOAD_PARSE_STARTED,LogLevel::Info,payload.length(),0,transactionId);
    // Keep parser output off the small loop stack; commit only validated boards.
    static ArrivalBoard board;
    const auto result = decodeArrivalPayload(std::string(payload.c_str(), payload.length()), board);
    if (result == ArrivalPayloadResult::valid) {
      DiagnosticStore::shared().event(EventCode::PAYLOAD_PARSE_SUCCESS,LogLevel::Info,0,0,transactionId);
      DisplayController::setPlatforms(board, millis());
      transitUpdateStage(transactionId,"STATE_COMMITTED");
      const auto renderGeneration=DisplayController::requestRender(transactionId);
      transitUpdateStage(transactionId,"RENDER_REQUESTED",renderGeneration);
      DiagnosticStore::shared().event(EventCode::DATA_APPLIED,LogLevel::Info,payload.length(),0,transactionId);
      acknowledgeTransitApplied(transactionId,payload.length());
      finishTransitRefresh(true);
      DiagnosticStore::shared().event(EventCode::FETCH_SUCCESS,LogLevel::Info,0,0,transactionId);
      InfoLog.println("Message received: arrival board updated");
      DebugLog.printf("[BLE] Received platformCount=%u\n", unsigned(board.platformCount));
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
      WarnLog.println(result == ArrivalPayloadResult::unavailable ? "[DISPLAY] Unavailable; retaining cached arrivals" : "[DISPLAY] Invalid payload; retaining cached arrivals");
    }
  }
  if (takeTransitRefreshFailure()) {
    MetricsStore::shared().recordBootDataFailure();
    DebugLog.println("[DISPLAY] Refresh failed; retaining cached arrivals");
  }
  DisplayController::tick(millis());
  // Display worker owns SPI; CPU/APB frequency stays pinned while it exists.
}

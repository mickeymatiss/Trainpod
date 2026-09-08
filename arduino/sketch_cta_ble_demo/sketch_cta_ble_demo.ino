#include <Arduino_GFX_Library.h>
#include "BleIntegration.h"
#include "ArrivalScreen.h"
#include "ArrivalPayload.h"
#include "PowerLifecycle.h"
#include "MetricsStore.h"
#include <esp_timer.h>

#define LCD_DC 15
#define LCD_CS 14
#define LCD_SCK 7
#define LCD_MOSI 6
#define LCD_RST 21
#define LCD_BL 22
#define BUTTON_PIN 9

Arduino_DataBus* bus = new Arduino_ESP32SPI(LCD_DC, LCD_CS, LCD_SCK, LCD_MOSI);
Arduino_GFX* gfx = new Arduino_ST7789(bus, LCD_RST, 0, true, 172, 320, 34, 0, 34, 0);
ArrivalScreen arrivalScreen(*gfx);
bool displayReady = false;
int lastButtonReading = HIGH, buttonState = HIGH;
uint32_t lastButtonChangeMs = 0;

void powerStateChanged(PowerState previous, PowerState next, uint32_t now);
PowerLifecycle powerLifecycle(powerStateChanged);

// All backlight/standby side effects pass through this one transition handler.
void powerStateChanged(PowerState previous, PowerState next, uint32_t now) {
  switch (next) {
    case PowerState::ACTIVE:
      if (previous == PowerState::SCREEN_OFF_STANDBY) {
        Serial.println("[POWER] SCREEN_OFF_STANDBY -> ACTIVE; restoring cached UI");
        arrivalScreen.setConnected(bleIsReady());
        if (displayReady) arrivalScreen.resume(now);
        analogWrite(LCD_BL, PowerConfig::ACTIVE_BRIGHTNESS);
        // Requests run in the normal BLE poll, after the old board is visible.
        setTransitRefreshPaused(false);
      } else {
        analogWrite(LCD_BL, PowerConfig::ACTIVE_BRIGHTNESS);
        Serial.println(previous == PowerState::DIMMED ? "[POWER] DIMMED -> ACTIVE" : "[POWER] State: ACTIVE");
      }
      break;
    case PowerState::DIMMED:
      analogWrite(LCD_BL, PowerConfig::DIM_BRIGHTNESS);
      Serial.println("[POWER] Inactivity timeout: ACTIVE -> DIMMED");
      break;
    case PowerState::SCREEN_OFF_STANDBY:
      setTransitRefreshPaused(true);
      arrivalScreen.suspend(now);
      analogWrite(LCD_BL, 0);
      MetricsStore::shared().recordBootDataFailure(); // No-op after a startup outcome.
      MetricsStore::shared().flush(); // Save short sessions; no BLE mutex is held.
      Serial.println("[POWER] DIMMED -> SCREEN_OFF_STANDBY; CPU awake, BLE available");
      break;
  }
}

// Preserve cached arrivals and their timestamp while refreshing.
void beginRefreshDisplay() {}

void setup() {
  Serial.begin(115200);
  MetricsStore::shared().begin();
  pinMode(LCD_BL, OUTPUT);
  pinMode(BUTTON_PIN, INPUT_PULLUP);
  analogWrite(LCD_BL, 0);
  lastButtonReading = buttonState = digitalRead(BUTTON_PIN);
  lastButtonChangeMs = millis();
  displayReady = gfx->begin();
  if (displayReady) {
    gfx->setRotation(1); // Existing physical panel: 320 x 172.
    arrivalScreen.begin(millis());
    arrivalScreen.setBatteryPercent(-1); // No battery ADC configured on this prototype.
  } else Serial.println("LCD init failed");
  setupBleIntegration(beginRefreshDisplay);
  powerLifecycle.begin(millis());
}

void loop() {
  const uint32_t now = millis();
  // Debounce once, before inactivity processing: a real press wins at a timeout.
  const int reading = digitalRead(BUTTON_PIN);
  if (reading != lastButtonReading) lastButtonChangeMs = now;
  if (uint32_t(now-lastButtonChangeMs) >= PowerConfig::BUTTON_DEBOUNCE_MS && reading != buttonState) {
    buttonState = reading;
    if (buttonState == LOW) {
      MetricsStore::shared().recordButtonPress();
      const auto action = powerLifecycle.buttonPressed(now);
      if (action == PowerButtonAction::WAKE_ONLY) {
        Serial.println("[POWER] Wake-only button press consumed");
      } else if (!bleWakeTestEnabled()) {
        arrivalScreen.nextPlatform(now);
      }
    }
  }
  lastButtonReading = reading;
  powerLifecycle.tick(now);

  // BLE stays alive in standby; its generic request policy is explicitly paused.
  pollBleIntegration();
  MetricsStore::shared().tick(millis()); // Still flush periodically in screen-off standby.
  if (powerLifecycle.isStandby()) return;

  arrivalScreen.setConnected(bleIsReady());
  String payload;
  if (takeTransitPayload(payload)) {
    ArrivalBoard board;
    const auto result = decodeArrivalPayload(std::string(payload.c_str(), payload.length()), board);
    if (result == ArrivalPayloadResult::valid) {
      arrivalScreen.setPlatforms(board, now);
      if(displayReady) {
        const uint64_t latencyMs=esp_timer_get_time()/1000;
        MetricsStore::shared().recordBootToData(latencyMs > UINT32_MAX ? UINT32_MAX : uint32_t(latencyMs));
      }
      finishTransitRefresh(true);
      Serial.println("[DISPLAY] Arrival board accepted");
    } else {
      MetricsStore::shared().recordBootDataFailure();
      finishTransitRefresh(false);
      Serial.println(result == ArrivalPayloadResult::unavailable ? "[DISPLAY] Unavailable; retaining cached arrivals" : "[DISPLAY] Invalid payload; retaining cached arrivals");
    }
  }
  if (takeTransitRefreshFailure()) {
    MetricsStore::shared().recordBootDataFailure();
    Serial.println("[DISPLAY] Refresh failed; retaining cached arrivals");
  }
  if (displayReady) arrivalScreen.tick(now);
}

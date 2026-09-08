#include <Arduino_GFX_Library.h>
#include "BleIntegration.h"
#include "ArrivalScreen.h"
#include "ArrivalPayload.h"

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

// Preserve cached arrivals and their timestamp while refreshing.
void beginRefreshDisplay() {}

void setup() {
  Serial.begin(115200);
  pinMode(LCD_BL, OUTPUT);
  pinMode(BUTTON_PIN, INPUT_PULLUP);
  analogWrite(LCD_BL, 30);
  displayReady = gfx->begin();
  if (displayReady) {
    gfx->setRotation(1); // Existing physical panel: 320 x 172.
    arrivalScreen.begin(millis());
    arrivalScreen.setBatteryPercent(-1); // No battery ADC configured on this prototype.
  } else Serial.println("LCD init failed");
  setupBleIntegration(beginRefreshDisplay);
}

void loop() {
  pollBleIntegration();
  const uint32_t now = millis();
  arrivalScreen.setConnected(bleIsConnected());
  String payload;
  if (takeTransitPayload(payload)) {
    ArrivalBoard board;
    const auto result = decodeArrivalPayload(std::string(payload.c_str(), payload.length()), board);
    if (result == ArrivalPayloadResult::valid) {
      arrivalScreen.setPlatforms(board, now);
      finishTransitRefresh(true);
      Serial.println("[DISPLAY] Arrival board accepted");
    } else {
      finishTransitRefresh(false);
      Serial.println(result == ArrivalPayloadResult::unavailable ? "[DISPLAY] Unavailable; retaining cached arrivals" : "[DISPLAY] Invalid payload; retaining cached arrivals");
    }
  }
  if (takeTransitRefreshFailure()) Serial.println("[DISPLAY] Refresh failed; retaining cached arrivals");
  const int reading = digitalRead(BUTTON_PIN);
  if (reading != lastButtonReading) lastButtonChangeMs = now;
  if (uint32_t(now-lastButtonChangeMs) >= 40 && reading != buttonState) {
    buttonState = reading;
    if (buttonState == LOW && !bleWakeTestEnabled()) arrivalScreen.nextPlatform(now);
  }
  lastButtonReading = reading;
  if (displayReady) arrivalScreen.tick(now);
}

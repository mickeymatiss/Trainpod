#include "../diagnostics/SerialLog.h"
#pragma once
#include <Arduino.h>
#include <NimBLEDevice.h>
#include <atomic>

// Simulated BLE unavailability. The host stays initialized, preserving its address and GATT database.
class BleWakeTest {
public:
  void begin(NimBLEServer* server, void (*onWake)() = nullptr) {
    server_=server;
    onWake_=onWake;
    pinMode(BUTTON_PIN,INPUT_PULLUP);
    reading_=stable_=digitalRead(BUTTON_PIN);
  }
  bool enabled() const { return enabled_.load(); }
  bool onConnected(uint16_t handle) {
    if(off_.load()) { server_->disconnect(handle); return false; }
    handle_=handle;
    enabled_=false; // Resume normal payload reception after the wake reconnect.
    connectedEvent_=true;
    return true;
  }
  void onDisconnected(uint16_t handle) {
    if(handle_.load()==handle) handle_=BLE_HS_CONN_HANDLE_NONE;
    if(off_.load()) { NimBLEDevice::stopAdvertising(); offEvent_=true; }
    else startAdvertising();
  }
  void enterBleOffState() {
    const auto handle=handle_.load();
    if(handle==BLE_HS_CONN_HANDLE_NONE) { DebugLog.println("[WAKE] Connect the iPhone before ble off."); return; }
    enabled_=true;
    off_=true; // Set before disconnect so its callback cannot restart advertising.
    server_->advertiseOnDisconnect(false);
    NimBLEDevice::stopAdvertising();
    if(!server_->disconnect(handle)) {
      off_=false; enabled_=false;
      DebugLog.println("[WAKE] Disconnect request failed; BLE-off test not entered.");
      return;
    }
    DebugLog.printf("[WAKE] %lu ms: disconnect requested; advertising stopped. Await GPIO 9 button.\n",millis());
  }
  void wakeBle() {
    if(!off_.load() || handle_.load()!=BLE_HS_CONN_HANDLE_NONE) return;
    // poll() runs on the Arduino loop; show loading before enabling advertising.
    if(onWake_) onWake_();
    off_=false;
    startAdvertising();
    DebugLog.printf("[WAKE] %lu ms: button pressed; advertising same identity/service.\n",millis());
  }
  void startAdvertising() { if(!off_.load()) NimBLEDevice::startAdvertising(); }
  void poll() {
    if(connectedEvent_.exchange(false)) DebugLog.printf("[WAKE] %lu ms: BLE connection established; no payload sent.\n",millis());
    if(offEvent_.exchange(false)) DebugLog.printf("[WAKE] %lu ms: disconnected; BLE unavailable until button press.\n",millis());
    const int sample=digitalRead(BUTTON_PIN);
    const auto now=millis();
    if(sample!=reading_) { reading_=sample; changed_=now; }
    if(now-changed_>=40 && stable_!=reading_) {
      stable_=reading_;
      if(stable_==LOW) wakeBle();
    }
  }
private:
  static constexpr int BUTTON_PIN=9;
  NimBLEServer* server_=nullptr;
  void (*onWake_)()=nullptr;
  std::atomic<bool> enabled_{false}, off_{false}, connectedEvent_{false}, offEvent_{false};
  std::atomic<uint16_t> handle_{BLE_HS_CONN_HANDLE_NONE};
  int reading_=HIGH, stable_=HIGH;
  unsigned long changed_=0;
};

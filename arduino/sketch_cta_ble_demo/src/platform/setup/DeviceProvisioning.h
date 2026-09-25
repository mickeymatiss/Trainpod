#pragma once
#include <Arduino.h>
#include <NimBLEDevice.h>
#include <atomic>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>

// Owns setup eligibility and the one durable binding. Call begin/update/reset
// on the Arduino loop. BLE callbacks only read state or queue bounded frames.
class DeviceProvisioning {
public:
  enum State : uint8_t { Unprovisioned=0, SetupReady=1, Provisioned=2, StorageError=3 };
  static DeviceProvisioning& shared();
  void begin();
  bool provisioned() const { return provisioned_.load(); }
  bool keepsBleAvailable() const { return !provisioned() || preferencesPending_.load(); }
  State state() const;
  bool completeSetup(); // Arduino loop: finish only after preferences are saved.
  void buttonPressed();
  bool attach(NimBLEService* service);
  void detached();
  void connected(uint16_t peer);
  void disconnected();
  void update();
  bool clearProvisioning(); // Deliberate local reset; NEVER erases deviceId.
private:
  struct Record { uint32_t version=1; uint8_t app[16]{}; uint8_t key[32]{}; } record_;
  struct Frame { uint32_t epoch; uint8_t size; uint8_t data[20]; };
  class Callbacks final : public NimBLECharacteristicCallbacks {
    void onRead(NimBLECharacteristic*,NimBLEConnInfo&) override;
    void onWrite(NimBLECharacteristic*,NimBLEConnInfo&) override;
  } callbacks_;
  void receive(const uint8_t*,size_t,uint16_t);
  void respond(uint32_t token,uint8_t code);
  bool persist(const Record& record, bool preferencesPending);
  std::atomic<bool> provisioned_{false},storageReady_{false},window_{false},preferencesPending_{false};
  std::atomic<uint32_t> epoch_{0};
  std::atomic<uint16_t> peer_{BLE_HS_CONN_HANDLE_NONE};
  QueueHandle_t queue_=nullptr;
  NimBLECharacteristic *status_=nullptr,*command_=nullptr,*result_=nullptr;
  uint32_t token_=0,assemblyEpoch_=0,assemblyStarted_=0;
  uint8_t operation_=0,next_=0,credentials_[48]{};
};

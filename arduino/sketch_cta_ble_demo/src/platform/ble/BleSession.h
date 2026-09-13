#pragma once

#include <Arduino.h>
#include <NimBLEDevice.h>
#include <atomic>

enum class BleSessionState : uint8_t {
  Off,
  Starting,
  Advertising,
  Connected,
  Transferring,
  Completing,
  Stopping
};

class BleSessionObserver {
public:
  virtual ~BleSessionObserver() = default;
  virtual void onBleSessionTimeout() {}
  virtual bool onBleConnected(NimBLEServer* server, NimBLEConnInfo& info) = 0;
  virtual void onBleDisconnected(NimBLEConnInfo& info, int reason) = 0;
  virtual void onBleWrite(NimBLECharacteristic* characteristic, NimBLEConnInfo& info) = 0;
  virtual void onBleSubscribe(NimBLECharacteristic* characteristic, NimBLEConnInfo& info,
                              uint16_t value) = 0;
};

class BleSession {
public:
  static constexpr uint32_t SESSION_TIMEOUT_MS = 15000;
  static constexpr uint32_t COMPLETION_GRACE_MS = 350;
  static constexpr uint32_t MIN_CONNECTION_MS = 5000;
  static constexpr uint32_t DISCONNECT_TIMEOUT_MS = 1000;

  BleSession(const char* deviceName, const char* serviceUuid,
             const char* characteristicUuid, BleSessionObserver& observer);

  void beginSession();
  void openManualWindow();
  static constexpr uint32_t MANUAL_WINDOW_MS = 60000;
  void endSession();
  void abortSession(const char* reason);
  void update();
  void markTransactionComplete();
  void setPermissive(bool enabled);
  bool permissive() const { return permissive_.load(); }

  static bool anySessionActive();
  bool isActive() const { return state_.load() != BleSessionState::Off; }
  bool isConnected() const { return peer_.load() != BLE_HS_CONN_HANDLE_NONE; }
  bool isReady() const { return isConnected() && subscribed_.load() && !closePending_.load() && !diagnosticsActive(); }
  bool diagnosticsActive() const;
  bool sendDiagnosticNotification(const uint8_t* bytes, size_t count);
  size_t notificationCapacity() const;
  BleSessionState state() const { return state_.load(); }
  NimBLECharacteristic* characteristic() const { return characteristic_; }
  uint16_t peer() const { return peer_.load(); }

private:
  class ServerCallbacks final : public NimBLEServerCallbacks {
  public:
    explicit ServerCallbacks(BleSession& owner) : owner_(owner) {}
    void onConnect(NimBLEServer* server, NimBLEConnInfo& info) override;
    void onDisconnect(NimBLEServer* server, NimBLEConnInfo& info, int reason) override;
  private:
    BleSession& owner_;
  };

  class CharacteristicCallbacks final : public NimBLECharacteristicCallbacks {
  public:
    explicit CharacteristicCallbacks(BleSession& owner) : owner_(owner) {}
    void onWrite(NimBLECharacteristic* characteristic, NimBLEConnInfo& info) override;
    void onSubscribe(NimBLECharacteristic* characteristic, NimBLEConnInfo& info,
                     uint16_t value) override;
  private:
    BleSession& owner_;
  };

  void handleConnect(NimBLEServer* server, NimBLEConnInfo& info);
  void handleDisconnect(NimBLEConnInfo& info, int reason);
  void handleWrite(NimBLECharacteristic* characteristic, NimBLEConnInfo& info);
  void handleSubscribe(NimBLECharacteristic* characteristic, NimBLEConnInfo& info,
                       uint16_t value);
  bool connectionHoldSatisfied(uint32_t now) const;
  void shutdownStack();

  const char* deviceName_;
  const char* serviceUuid_;
  const char* characteristicUuid_;
  BleSessionObserver& observer_;
  ServerCallbacks serverCallbacks_;
  CharacteristicCallbacks characteristicCallbacks_;
  NimBLEServer* server_ = nullptr;
  NimBLECharacteristic* characteristic_ = nullptr;
  std::atomic<BleSessionState> state_{BleSessionState::Off};
  std::atomic<uint16_t> peer_{BLE_HS_CONN_HANDLE_NONE};
  std::atomic<bool> subscribed_{false};
  std::atomic<bool> disconnected_{false};
  std::atomic<bool> closePending_{false};
  std::atomic<bool> permissive_{false}; // Debug override; resets on reboot.
  std::atomic<uint32_t> connectedAtMs_{0};
  bool manualWindow_ = false; // Arduino loop owns the manual-window timer.
  uint32_t manualWindowStartedMs_ = 0;
  uint32_t manualRetryMs_ = 0;
  uint32_t sessionStartedMs_ = 0;
  uint32_t completionStartedMs_ = 0;
  uint32_t stoppingStartedMs_ = 0;
};

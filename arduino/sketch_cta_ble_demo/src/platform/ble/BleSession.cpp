#include "../diagnostics/SerialLog.h"
#include "BleSession.h"
#include "../device/DeviceIdentity.h"
#include "../power/NightBrightness.h"
#include "../diagnostics/DiagnosticExport.h"
#include "../power/PerformanceMode.h"

namespace { BleSession* radioSession = nullptr; }
bool BleSession::anySessionActive() { return radioSession && radioSession->isActive(); }
bool BleSession::diagnosticsActive() const { return DiagnosticExport::shared().busy(); }
bool BleSession::sendDiagnosticNotification(const uint8_t* bytes, size_t count) {
  return isConnected() && subscribed_.load() && state_.load() != BleSessionState::Stopping &&
    characteristic_ && characteristic_->notify(bytes,count,peer_.load());
}
size_t BleSession::notificationCapacity() const {
  return server_ && isConnected() ? size_t(server_->getPeerMTU(peer_.load())-3) : 20;
}

BleSession::BleSession(const char* deviceName, const char* serviceUuid,
                       const char* characteristicUuid, BleSessionObserver& observer)
    : deviceName_(deviceName), serviceUuid_(serviceUuid),
      characteristicUuid_(characteristicUuid), observer_(observer),
      serverCallbacks_(*this), characteristicCallbacks_(*this) { radioSession = this; }

void BleSession::openManualWindow() {
  manualWindowStartedMs_ = millis();
  manualRetryMs_ = manualWindowStartedMs_;
  manualWindow_ = true;
  closePending_ = false;
  if (state_.load() == BleSessionState::Completing) state_ = BleSessionState::Connected;
  beginSession();
  DebugLog.println("[BLE] Button hold: BLE open for 60 seconds");
}

void BleSession::beginSession() {
  if (state_.load() != BleSessionState::Off) return;
  if (!setPerformanceMode(PerformanceMode::ACTIVE)) {
    DebugLog.println("[CPU] Cannot reach 160 MHz; BLE start deferred");
    return;
  }

  const String deviceId = DeviceIdentity::getDeviceId();
  if (deviceId.isEmpty()) {
    WarnLog.println("[BLE] session aborted: persistent identity unavailable");
    return;
  }

  DebugLog.println("[BLE] session starting");
  DiagnosticStore::shared().event(EventCode::BLE_INIT_START,LogLevel::Info);
  state_ = BleSessionState::Starting;
  peer_ = BLE_HS_CONN_HANDLE_NONE;
  subscribed_ = false;
  disconnected_ = false;
  closePending_ = false;
  connectedAtMs_ = 0;

  if (!NimBLEDevice::init(deviceName_)) {
    state_ = BleSessionState::Off;
    DiagnosticStore::shared().event(EventCode::ERROR_GENERIC,LogLevel::Error,101);
    WarnLog.println("[BLE] session aborted: stack initialization failed");
    return;
  }
  DiagnosticStore::shared().event(EventCode::BLE_INIT_COMPLETE);
  NimBLEDevice::setMTU(128);
  server_ = NimBLEDevice::createServer();
  if (!server_) {
    DiagnosticStore::shared().event(EventCode::ERROR_GENERIC,LogLevel::Error,102);
    WarnLog.println("[BLE] session aborted: server creation failed");
    shutdownStack();
    return;
  }
  server_->advertiseOnDisconnect(false);
  // These callbacks are members of this reusable session object, not heap-owned by NimBLE.
  server_->setCallbacks(&serverCallbacks_, false);
  auto* service = server_->createService(serviceUuid_);
  if (!service) {
    DiagnosticStore::shared().event(EventCode::ERROR_GENERIC,LogLevel::Error,103);
    WarnLog.println("[BLE] session aborted: service creation failed");
    shutdownStack();
    return;
  }
  characteristic_ = service->createCharacteristic(
      characteristicUuid_,
      NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR | NIMBLE_PROPERTY::NOTIFY);
  if (!characteristic_) {
    DiagnosticStore::shared().event(EventCode::ERROR_GENERIC,LogLevel::Error,104);
    WarnLog.println("[BLE] session aborted: characteristic creation failed");
    shutdownStack();
    return;
  }
  characteristic_->setCallbacks(&characteristicCallbacks_);
  auto* identityCharacteristic = service->createCharacteristic(
      DeviceIdentity::characteristicUUID, NIMBLE_PROPERTY::READ, 35);
  if (!identityCharacteristic) {
    WarnLog.println("[BLE] session aborted: identity characteristic creation failed");
    shutdownStack();
    return;
  }
  identityCharacteristic->setValue(deviceId.c_str());
  service->start();

  auto* advertising = NimBLEDevice::getAdvertising();
  advertising->addServiceUUID(serviceUuid_);
  advertising->enableScanResponse(true);
  advertising->setName(deviceName_);
  sessionStartedMs_ = millis();
  state_ = BleSessionState::Advertising;
  if (!advertising->start()) {
    DiagnosticStore::shared().event(EventCode::ERROR_GENERIC,LogLevel::Error,105);
    WarnLog.println("[BLE] session aborted: advertising failed");
    shutdownStack();
    return;
  }
  DebugLog.println("[BLE] advertising");
  if (DiagnosticStore::shared().counters().advertisingSessions > 0)
    DiagnosticStore::shared().event(EventCode::BLE_ADVERTISING_RESTART);
  DiagnosticStore::shared().count(DiagnosticCounter::AdvertisingSession);
  DiagnosticStore::shared().event(EventCode::BLE_ADVERTISING_START,LogLevel::Info);
}

void BleSession::markTransactionComplete() {
  if (permissive() || manualWindow_) return;
  const auto state = state_.load();
  if (state != BleSessionState::Connected && state != BleSessionState::Transferring) return;
  completionStartedMs_ = millis();
  state_ = BleSessionState::Completing;
  DebugLog.println("[BLE] completion grace period");
}

void BleSession::abortSession(const char* reason) {
  if (permissive() || manualWindow_) return;
  if (!isActive() || state_.load() == BleSessionState::Stopping) return;
  if (reason && *reason) DebugLog.printf("[BLE] %s\n", reason);
  DebugLog.println("[BLE] session aborted");
  endSession();
}

void BleSession::endSession() {
  if (permissive() || manualWindow_) return;
  if (state_.load() == BleSessionState::Off || state_.load() == BleSessionState::Stopping) return;
  if (diagnosticsActive()) { closePending_ = true; return; }
  const uint32_t now = millis();
  if (isConnected() && !connectionHoldSatisfied(now)) {
    if (!closePending_.exchange(true)) {
      DebugLog.println("[BLE] close pending; holding connection for minimum 5s");
    }
    return;
  }
  closePending_ = false;
  if (state_.load() == BleSessionState::Advertising)
    DiagnosticStore::shared().event(EventCode::BLE_ADVERTISING_STOP);
  state_ = BleSessionState::Stopping;
  stoppingStartedMs_ = now;
  NimBLEDevice::stopAdvertising();
  const uint16_t handle = peer_.load();
  if (handle != BLE_HS_CONN_HANDLE_NONE && server_) {
    DebugLog.println("[BLE] disconnecting");
    if (server_->disconnect(handle)) return;
  }
  shutdownStack();
}

void BleSession::update() {
  const uint32_t windowNow = millis();
  if (manualWindow_ && uint32_t(windowNow - manualWindowStartedMs_) >= MANUAL_WINDOW_MS) {
    manualWindow_ = false;
    DebugLog.println("[BLE] 60-second button window ended; normal lifecycle restored");
    endSession();
  }
  // A phone disconnect must not end the user's availability window. Restart
  // advertising after teardown, even if no train refresh is currently needed.
  if (manualWindow_ && state_.load() == BleSessionState::Off &&
      int32_t(windowNow - manualRetryMs_) >= 0) {
    manualRetryMs_ = windowNow + 1000;
    beginSession();
  }
  DiagnosticExport::shared().update(*this);
  const auto state = state_.load();
  if (state == BleSessionState::Off) return;
  if (diagnosticsActive()) return; // Export has its own bounded 60-second window.

  const uint32_t now = millis();
  if (closePending_.load()) {
    if (connectionHoldSatisfied(now)) endSession();
    return;
  }

  if (state == BleSessionState::Stopping) {
    if (peer_.load() == BLE_HS_CONN_HANDLE_NONE || disconnected_.exchange(false) ||
        uint32_t(now - stoppingStartedMs_) >= DISCONNECT_TIMEOUT_MS) shutdownStack();
    return;
  }

  if (state == BleSessionState::Completing) {
    if (uint32_t(now - completionStartedMs_) >= COMPLETION_GRACE_MS &&
        connectionHoldSatisfied(now)) endSession();
    return;
  }

  if (permissive() || manualWindow_) return;
  if (uint32_t(now - sessionStartedMs_) >= SESSION_TIMEOUT_MS) {
    DiagnosticStore::shared().count(DiagnosticCounter::BleTimeout);
    DiagnosticStore::shared().event(EventCode::BLE_TIMEOUT,LogLevel::Warn);
    observer_.onBleSessionTimeout();
    DebugLog.println(state == BleSessionState::Advertising
                       ? "[BLE] connection timeout"
                       : "[BLE] transfer failed: session timeout");
    abortSession(nullptr);
  }
}

void BleSession::setPermissive(bool enabled) {
  permissive_ = enabled;
  if (enabled) {
    closePending_ = false;
    if (state_.load() == BleSessionState::Completing)
      state_ = BleSessionState::Connected;
    beginSession();
  } else {
    // Resume normal close safeguards, including the minimum connection hold.
    endSession();
  }
  DebugLog.println(enabled ? "[BLE] Permissive ON: lifecycle disconnects disabled (until reboot)" :
                           "[BLE] Permissive OFF: normal lifecycle restored");
}

void BleSession::shutdownStack() {
  NimBLEDevice::stopAdvertising();
  // Runtime shutdown only: deinit never clears bonds, keys, identity, or peer data.
  NimBLEDevice::deinit(true);
  server_ = nullptr;
  characteristic_ = nullptr;
  peer_ = BLE_HS_CONN_HANDLE_NONE;
  subscribed_ = false;
  disconnected_ = false;
  closePending_ = false;
  connectedAtMs_ = 0;
  state_ = BleSessionState::Off;
  DebugLog.println("[BLE] session stopped; BLE OFF");
  DiagnosticStore::shared().event(EventCode::BLE_SESSION_STOPPED,LogLevel::Info);
}

void BleSession::handleConnect(NimBLEServer* server, NimBLEConnInfo& info) {
  const auto state = state_.load();
  if (state != BleSessionState::Advertising || peer_.load() != BLE_HS_CONN_HANDLE_NONE ||
      !observer_.onBleConnected(server, info)) {
    server->disconnect(info.getConnHandle());
    return;
  }
  peer_ = info.getConnHandle();
  subscribed_ = false;
  connectedAtMs_ = millis();
  closePending_ = false;
  state_ = BleSessionState::Connected;
  DiagnosticStore::shared().beginConnection();
  DiagnosticStore::shared().event(EventCode::BLE_ADVERTISING_STOP);
  InfoLog.println("BLE connected");
  DiagnosticStore::shared().event(EventCode::BLE_CONNECTED,LogLevel::Info);
}

void BleSession::handleDisconnect(NimBLEConnInfo& info, int reason) {
  if (info.getConnHandle() != peer_.load()) return;
  DiagnosticExport::shared().disconnected();
  DiagnosticStore::shared().count(DiagnosticCounter::BleDisconnect);
  DiagnosticStore::shared().event(EventCode::BLE_DISCONNECTED,state_.load() == BleSessionState::Stopping ? LogLevel::Info : LogLevel::Warn,reason);
  observer_.onBleDisconnected(info, reason);
  peer_ = BLE_HS_CONN_HANDLE_NONE;
  subscribed_ = false;
  disconnected_ = true;
  closePending_ = false;
  if (state_.load() != BleSessionState::Stopping) {
    WarnLog.println("[BLE] unexpected disconnect");
    state_ = BleSessionState::Stopping;
    stoppingStartedMs_ = millis();
  }
}

void BleSession::handleWrite(NimBLECharacteristic* characteristic, NimBLEConnInfo& info) {
  if (info.getConnHandle() != peer_.load()) return;
  if (state_.load() == BleSessionState::Stopping) return;
  const auto bytes = characteristic->getValue();
  if ((bytes.size() == 14 && bytes[0] == 'T' && bytes[1] == '1') ||
      (bytes.size() == 16 && bytes[0] == 'T' && bytes[1] == '2')) {
    uint64_t unixMs = 0; uint32_t sessionId = 0;
    for (int i=0;i<8;++i) unixMs |= uint64_t(bytes[2+i]) << (8*i);
    for (int i=0;i<4;++i) sessionId |= uint32_t(bytes[10+i]) << (8*i);
    DiagnosticStore::shared().timeSync(int64_t(unixMs),sessionId);
    if(bytes.size()==16) {
      const uint16_t encoded=uint16_t(uint8_t(bytes[14])) | (uint16_t(uint8_t(bytes[15]))<<8);
      const int offset=encoded>=32768 ? int(encoded)-65536 : int(encoded);
      NightBrightness::shared().sync(unixMs,offset,sessionId);
    }
    return;
  }
  if (DiagnosticExport::shared().acceptCommand(bytes.data(),bytes.size())) return;
  if (diagnosticsActive()) return;
  if (closePending_.load()) return;
  const auto state = state_.load();
  if (state != BleSessionState::Connected && state != BleSessionState::Transferring) return;
  if (state == BleSessionState::Connected) {
    state_ = BleSessionState::Transferring;
    DebugLog.println("[BLE] transfer started");
  }
  observer_.onBleWrite(characteristic, info);
}

void BleSession::handleSubscribe(NimBLECharacteristic* characteristic, NimBLEConnInfo& info,
                                 uint16_t value) {
  if (info.getConnHandle() != peer_.load()) return;
  subscribed_ = (value & 1) != 0;
  observer_.onBleSubscribe(characteristic, info, value);
}

bool BleSession::connectionHoldSatisfied(uint32_t now) const {
  return !isConnected() || uint32_t(now - connectedAtMs_.load()) >= MIN_CONNECTION_MS;
}

void BleSession::ServerCallbacks::onConnect(NimBLEServer* server, NimBLEConnInfo& info) {
  owner_.handleConnect(server, info);
}

void BleSession::ServerCallbacks::onDisconnect(NimBLEServer*, NimBLEConnInfo& info, int reason) {
  owner_.handleDisconnect(info, reason);
}

void BleSession::CharacteristicCallbacks::onWrite(NimBLECharacteristic* characteristic,
                                                   NimBLEConnInfo& info) {
  owner_.handleWrite(characteristic, info);
}

void BleSession::CharacteristicCallbacks::onSubscribe(NimBLECharacteristic* characteristic,
                                                       NimBLEConnInfo& info, uint16_t value) {
  owner_.handleSubscribe(characteristic, info, value);
}

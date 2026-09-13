#pragma once
#include <Arduino.h>
#include <Preferences.h>
#include <freertos/FreeRTOS.h>

enum class LogLevel : uint8_t { Debug, Info, Warn, Error };
enum class EventCode : uint16_t {
  BOOT_START, BOOT_READY, BLE_INIT_START, BLE_INIT_COMPLETE,
  BLE_ADVERTISING_START, BLE_ADVERTISING_RESTART, BLE_ADVERTISING_STOP,
  BLE_CONNECTED, BLE_DISCONNECTED, BLE_SESSION_STOPPED, BLE_TIMEOUT,
  DATA_REQUEST_SENT, DATA_REQUEST_FAILED, DATA_REQUEST_TIMEOUT,
  DATA_RESPONSE_STARTED, DATA_RESPONSE_COMPLETE,
  FETCH_REQUESTED, FETCH_SUCCESS, FETCH_FAILURE,
  PAYLOAD_RX_START, PAYLOAD_RX_COMPLETE, PAYLOAD_PARSE_FAILURE,
  DISPLAY_UPDATE_START, DISPLAY_UPDATE_COMPLETE, STARTUP_COMPLETE, STARTUP_TIMEOUT,
  TIME_SYNC_RECEIVED, TIME_SYNC_UPDATED, DIAGNOSTIC_EXPORT_REQUESTED,
  DIAGNOSTIC_EXPORT_COMPLETE, DIAGNOSTIC_EXPORT_FAILED,
  POWER_ACTIVE, POWER_DIMMED, POWER_STANDBY, BUTTON_PRESSED, ERROR_GENERIC,
  RESPONSE_RX_STARTED, RESPONSE_RX_CHUNK, RESPONSE_RX_COMPLETE, RESPONSE_RX_FAILED, PAYLOAD_PARSE_STARTED, PAYLOAD_PARSE_SUCCESS, DATA_APPLIED, DATA_APPLIED_ACK_QUEUED, DATA_APPLIED_ACK_FAILED, DISPLAY_UPDATED
};
enum class DiagnosticCounter { ExportAttempt, ExportSuccess, ExportFailure, BleTimeout, BleDisconnect, DataTimeout, InvalidPayload, StartupTimeout, AdvertisingSession, TimeSync };
struct DiagnosticCounters {
  uint32_t version = 2;
  uint32_t exportsAttempted = 0, exportsSucceeded = 0, exportsFailed = 0;
  uint32_t bleTimeouts = 0, bleDisconnects = 0, dataTimeouts = 0, invalidPayloads = 0;
  uint32_t lastResetReason = 0;
  uint32_t startupTimeouts = 0, advertisingSessions = 0, timeSyncs = 0, exportPending = 0;
};
struct DiagnosticEntry {
  uint64_t sequence = 0, uptimeMs = 0;
  int64_t unixTimeMs = 0;
  uint32_t sessionId = 0;
  uint64_t transactionId = 0;
  int32_t value1 = 0, value2 = 0;
  EventCode eventCode = EventCode::BOOT_START;
  LogLevel level = LogLevel::Info;
  bool timestampSynced = false;
};
struct TransactionTrace {
  uint64_t id=0;
  DiagnosticEntry events[24];
  size_t count=0;
};
struct DiagnosticSnapshot {
  TransactionTrace transactions[5];
  DiagnosticEntry logs[256], errors[32];
  size_t logCount = 0, errorCount = 0;
  uint64_t cutoff = 0;
  int64_t unixOffsetMs = 0, phoneUnixTimeMs = 0;
  uint64_t deviceUptimeMsAtSync = 0;
  uint32_t sessionId = 0;
  bool timestampSynced = false;
};

// Fixed RAM event rings. Lifetime counters use their own versioned NVS blob.
class DiagnosticStore {
public:
  static DiagnosticStore& shared();
  void begin();
  void event(EventCode code, LogLevel level = LogLevel::Info, int32_t value1 = 0, int32_t value2 = 0, uint64_t transactionId = 0);
  void retainTransaction(uint64_t id);
  static const char* eventName(EventCode code);
  void beginConnection();
  void timeSync(int64_t phoneUnixTimeMs, uint32_t sessionId);
  void startupComplete();
  void count(DiagnosticCounter counter);
  void snapshot(DiagnosticSnapshot& result);
  void purgeThrough(uint64_t sequence);
  DiagnosticCounters counters();
  void tick(uint32_t now);
  bool flush();
private:
  TransactionTrace transactions_[5];
  size_t nextTransaction_ = 0;
  DiagnosticEntry logs_[256], errors_[32];
  size_t logHead_ = 0, logCount_ = 0, errorHead_ = 0, errorCount_ = 0;
  uint64_t sequence_ = 0, syncUptime_ = 0;
  int64_t unixOffset_ = 0, syncUnix_ = 0;
  uint32_t sessionId_ = 0;
  bool synced_ = false, startupDone_ = false, startupTimedOut_ = false;
  EventCode startupState_ = EventCode::BOOT_START;
  portMUX_TYPE mutex_ = portMUX_INITIALIZER_UNLOCKED;
  DiagnosticCounters counters_;
  Preferences preferences_;
  bool ready_ = false, dirty_ = false, checkpoint_ = false;
  uint32_t generation_ = 0, lastFlush_ = 0;
};

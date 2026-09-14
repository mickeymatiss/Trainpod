#include "DiagnosticStore.h"
#include "../power/PerformanceMode.h"
#include <esp_system.h>
#include <esp_timer.h>
#include <cstring>
#include <algorithm>

DiagnosticStore& DiagnosticStore::shared() { static DiagnosticStore store; return store; }
void DiagnosticStore::begin() {
  ready_ = preferences_.begin("device_diag", false);
  if (ready_ && preferences_.isKey("counters")) {
    DiagnosticCounters stored;
    if (preferences_.getBytesLength("counters") == sizeof(stored) &&
        preferences_.getBytes("counters", &stored, sizeof(stored)) == sizeof(stored) && stored.version == 2) counters_ = stored;
    else if (preferences_.getBytesLength("counters") == 36) {
      uint32_t legacy[9]{};
      if (preferences_.getBytes("counters",legacy,sizeof(legacy)) == sizeof(legacy) && legacy[0] == 1) {
        memcpy(&counters_,legacy,sizeof(legacy)); counters_.version = 2;
      } else { preferences_.end(); ready_ = false; }
    } else { preferences_.end(); ready_ = false; }
  }
  // Resolve exports interrupted by reset before recording this boot.
  const uint32_t unresolved = counters_.exportPending;
  counters_.exportsFailed += std::min(unresolved, UINT32_MAX-counters_.exportsFailed);
  counters_.exportPending = 0;
  counters_.lastResetReason = uint32_t(esp_reset_reason());
  dirty_ = true; ++generation_;
  event(EventCode::BOOT_START);
  flush();
}
const char* DiagnosticStore::eventName(EventCode code) {
  switch (code) {
    case EventCode::BOOT_START: return "BOOT_START";
    case EventCode::BOOT_READY: return "BOOT_READY";
    case EventCode::BLE_INIT_START: return "BLE_INIT_START";
    case EventCode::BLE_INIT_COMPLETE: return "BLE_INIT_COMPLETE";
    case EventCode::BLE_ADVERTISING_START: return "BLE_ADVERTISING_START";
    case EventCode::BLE_ADVERTISING_RESTART: return "BLE_ADVERTISING_RESTART";
    case EventCode::BLE_ADVERTISING_STOP: return "BLE_ADVERTISING_STOP";
    case EventCode::BLE_CONNECTED: return "BLE_CONNECTED";
    case EventCode::BLE_DISCONNECTED: return "BLE_DISCONNECTED";
    case EventCode::BLE_SESSION_STOPPED: return "BLE_SESSION_STOPPED";
    case EventCode::BLE_TIMEOUT: return "BLE_TIMEOUT";
    case EventCode::DATA_REQUEST_SENT: return "DATA_REQUEST_SENT";
    case EventCode::DATA_REQUEST_FAILED: return "DATA_REQUEST_FAILED";
    case EventCode::DATA_REQUEST_TIMEOUT: return "DATA_REQUEST_TIMEOUT";
    case EventCode::DATA_RESPONSE_STARTED: return "DATA_RESPONSE_STARTED";
    case EventCode::DATA_RESPONSE_COMPLETE: return "DATA_RESPONSE_COMPLETE";
    case EventCode::FETCH_REQUESTED: return "FETCH_REQUESTED";
    case EventCode::FETCH_SUCCESS: return "FETCH_SUCCESS";
    case EventCode::FETCH_FAILURE: return "FETCH_FAILURE";
    case EventCode::PAYLOAD_RX_START: return "PAYLOAD_RX_START";
    case EventCode::PAYLOAD_RX_COMPLETE: return "PAYLOAD_RX_COMPLETE";
    case EventCode::PAYLOAD_PARSE_FAILURE: return "PAYLOAD_PARSE_FAILURE";
    case EventCode::DISPLAY_UPDATE_START: return "DISPLAY_UPDATE_START";
    case EventCode::DISPLAY_UPDATE_COMPLETE: return "DISPLAY_UPDATE_COMPLETE";
    case EventCode::STARTUP_COMPLETE: return "STARTUP_COMPLETE";
    case EventCode::STARTUP_TIMEOUT: return "STARTUP_TIMEOUT";
    case EventCode::TIME_SYNC_RECEIVED: return "TIME_SYNC_RECEIVED";
    case EventCode::TIME_SYNC_UPDATED: return "TIME_SYNC_UPDATED";
    case EventCode::DIAGNOSTIC_EXPORT_REQUESTED: return "DIAGNOSTIC_EXPORT_REQUESTED";
    case EventCode::DIAGNOSTIC_EXPORT_COMPLETE: return "DIAGNOSTIC_EXPORT_COMPLETE";
    case EventCode::DIAGNOSTIC_EXPORT_FAILED: return "DIAGNOSTIC_EXPORT_FAILED";
    case EventCode::POWER_ACTIVE: return "POWER_ACTIVE";
    case EventCode::POWER_DIMMED: return "POWER_DIMMED";
    case EventCode::POWER_STANDBY: return "POWER_STANDBY";
    case EventCode::BUTTON_PRESSED: return "BUTTON_PRESSED";
    case EventCode::ERROR_GENERIC: return "ERROR_GENERIC";
    case EventCode::RESPONSE_RX_STARTED: return "RESPONSE_RX_STARTED";
    case EventCode::RESPONSE_RX_CHUNK: return "RESPONSE_RX_CHUNK";
    case EventCode::RESPONSE_RX_COMPLETE: return "RESPONSE_RX_COMPLETE";
    case EventCode::RESPONSE_RX_FAILED: return "RESPONSE_RX_FAILED";
    case EventCode::PAYLOAD_PARSE_STARTED: return "PAYLOAD_PARSE_STARTED";
    case EventCode::PAYLOAD_PARSE_SUCCESS: return "PAYLOAD_PARSE_SUCCESS";
    case EventCode::DATA_APPLIED: return "DATA_APPLIED";
    case EventCode::DATA_APPLIED_ACK_QUEUED: return "DATA_APPLIED_ACK_QUEUED";
    case EventCode::DATA_APPLIED_ACK_FAILED: return "DATA_APPLIED_ACK_FAILED";
    case EventCode::DISPLAY_UPDATED: return "DISPLAY_UPDATED";
  }
  return "ERROR_GENERIC";
}
void DiagnosticStore::retainTransaction(uint64_t id) {
  if (!id) return;
  portENTER_CRITICAL(&mutex_);
  for (const auto& trace : transactions_) if (trace.id == id) { portEXIT_CRITICAL(&mutex_); return; }
  auto& trace = transactions_[nextTransaction_]; trace.id=id; trace.count=0;
  nextTransaction_=(nextTransaction_+1)%5;
  portEXIT_CRITICAL(&mutex_);
}
void DiagnosticStore::event(EventCode code, LogLevel level, int32_t value1, int32_t value2, uint64_t transactionId) {
  // Keep detailed traces, but classify routine lifecycle/transport work as debug.
  if(level==LogLevel::Info) {
    switch(code) {
      case EventCode::BOOT_START: case EventCode::BOOT_READY:
      case EventCode::BLE_INIT_START: case EventCode::BLE_INIT_COMPLETE:
      case EventCode::BLE_ADVERTISING_START: case EventCode::BLE_ADVERTISING_RESTART:
      case EventCode::BLE_ADVERTISING_STOP: case EventCode::BLE_DISCONNECTED:
      case EventCode::BLE_SESSION_STOPPED: case EventCode::DATA_REQUEST_SENT:
      case EventCode::DATA_RESPONSE_STARTED: case EventCode::DATA_RESPONSE_COMPLETE:
      case EventCode::FETCH_REQUESTED: case EventCode::FETCH_SUCCESS:
      case EventCode::PAYLOAD_RX_START: case EventCode::PAYLOAD_RX_COMPLETE:
      case EventCode::DISPLAY_UPDATE_START: case EventCode::DISPLAY_UPDATE_COMPLETE:
      case EventCode::STARTUP_COMPLETE: case EventCode::TIME_SYNC_RECEIVED:
      case EventCode::TIME_SYNC_UPDATED: case EventCode::POWER_ACTIVE:
      case EventCode::POWER_DIMMED: case EventCode::POWER_STANDBY:
      case EventCode::BUTTON_PRESSED: case EventCode::RESPONSE_RX_STARTED:
      case EventCode::RESPONSE_RX_CHUNK: case EventCode::RESPONSE_RX_COMPLETE:
      case EventCode::PAYLOAD_PARSE_STARTED: case EventCode::PAYLOAD_PARSE_SUCCESS:
      case EventCode::DATA_APPLIED_ACK_QUEUED: case EventCode::DISPLAY_UPDATED:
        level=LogLevel::Debug; break;
      default: break;
    }
  }
  DiagnosticEntry entry;
  entry.transactionId = transactionId;
  entry.eventCode = code; entry.level = level; entry.value1 = value1; entry.value2 = value2;
  portENTER_CRITICAL(&mutex_);
  entry.uptimeMs = uint64_t(esp_timer_get_time()) / 1000;
  if (code == EventCode::TIME_SYNC_RECEIVED || code == EventCode::TIME_SYNC_UPDATED)
    entry.value1 = int32_t(entry.uptimeMs - syncUptime_);
  entry.sequence = ++sequence_;
  entry.timestampSynced = synced_; entry.sessionId = sessionId_;
  entry.unixTimeMs = synced_ ? int64_t(entry.uptimeMs) + unixOffset_ : 0;
  logs_[(logHead_ + logCount_) % 256] = entry;
  if (logCount_ < 256) ++logCount_; else logHead_ = (logHead_ + 1) % 256;
  if (level == LogLevel::Warn || level == LogLevel::Error) {
    errors_[(errorHead_ + errorCount_) % 32] = entry;
    if (errorCount_ < 32) ++errorCount_; else errorHead_ = (errorHead_ + 1) % 32;
  }
  if (transactionId && code != EventCode::RESPONSE_RX_CHUNK) {
    for (auto& trace : transactions_) if (trace.id == transactionId) {
      if (trace.count < 24) trace.events[trace.count++] = entry;
      else { memmove(trace.events+1,trace.events+2,22*sizeof(DiagnosticEntry)); trace.events[23]=entry; }
      break;
    }
  }
  switch (code) {
    case EventCode::BOOT_START:
    case EventCode::BLE_INIT_START: case EventCode::BLE_INIT_COMPLETE:
    case EventCode::BLE_ADVERTISING_START: case EventCode::BLE_CONNECTED:
    case EventCode::DATA_REQUEST_SENT: case EventCode::PAYLOAD_RX_START:
    case EventCode::PAYLOAD_RX_COMPLETE: case EventCode::PAYLOAD_PARSE_FAILURE:
      if (!startupDone_) startupState_ = code;
      break;
    case EventCode::DISPLAY_UPDATE_START: case EventCode::DISPLAY_UPDATE_COMPLETE:
      if (!startupDone_ && value1) startupState_ = code;
      break;
    default: break;
  }
  portEXIT_CRITICAL(&mutex_);
}
void DiagnosticStore::beginConnection() {
  portENTER_CRITICAL(&mutex_);
  sessionId_ = 0; // Unknown until this connection sends its shared identifier.
  portEXIT_CRITICAL(&mutex_);
}
void DiagnosticStore::timeSync(int64_t phoneUnixTimeMs, uint32_t sessionId) {
  if (phoneUnixTimeMs < 1577836800000LL || phoneUnixTimeMs > 4102444800000LL || !sessionId) return;
  portENTER_CRITICAL(&mutex_);
  syncUptime_ = uint64_t(esp_timer_get_time()) / 1000;
  syncUnix_ = phoneUnixTimeMs;
  unixOffset_ = phoneUnixTimeMs - int64_t(syncUptime_);
  const bool updated = synced_;
  synced_ = true; sessionId_ = sessionId;
  portEXIT_CRITICAL(&mutex_);
  count(DiagnosticCounter::TimeSync);
  event(EventCode::TIME_SYNC_RECEIVED);
  if (updated) event(EventCode::TIME_SYNC_UPDATED);
}
void DiagnosticStore::startupComplete() {
  portENTER_CRITICAL(&mutex_);
  const bool first = !startupDone_;
  startupDone_ = true;
  portEXIT_CRITICAL(&mutex_);
  if (first) event(EventCode::STARTUP_COMPLETE);
}
void DiagnosticStore::count(DiagnosticCounter counter) {
  portENTER_CRITICAL(&mutex_);
  uint32_t* value = nullptr;
  switch (counter) {
    case DiagnosticCounter::ExportAttempt: value = &counters_.exportsAttempted; break;
    case DiagnosticCounter::ExportSuccess: value = &counters_.exportsSucceeded; break;
    case DiagnosticCounter::ExportFailure: value = &counters_.exportsFailed; break;
    case DiagnosticCounter::BleTimeout: value = &counters_.bleTimeouts; break;
    case DiagnosticCounter::BleDisconnect: value = &counters_.bleDisconnects; break;
    case DiagnosticCounter::DataTimeout: value = &counters_.dataTimeouts; break;
    case DiagnosticCounter::InvalidPayload: value = &counters_.invalidPayloads; break;
    case DiagnosticCounter::StartupTimeout: value = &counters_.startupTimeouts; break;
    case DiagnosticCounter::AdvertisingSession: value = &counters_.advertisingSessions; break;
    case DiagnosticCounter::TimeSync: value = &counters_.timeSyncs; break;
  }
  if (counter == DiagnosticCounter::ExportAttempt && counters_.exportPending != UINT32_MAX) ++counters_.exportPending;
  if ((counter == DiagnosticCounter::ExportSuccess || counter == DiagnosticCounter::ExportFailure) && counters_.exportPending) --counters_.exportPending;
  if (*value != UINT32_MAX) ++*value;
  dirty_ = true; checkpoint_ = true; ++generation_;
  portEXIT_CRITICAL(&mutex_);
}
void DiagnosticStore::snapshot(DiagnosticSnapshot& result) {
  portENTER_CRITICAL(&mutex_);
  result.unixOffsetMs = unixOffset_; result.phoneUnixTimeMs = syncUnix_;
  result.deviceUptimeMsAtSync = syncUptime_; result.sessionId = sessionId_; result.timestampSynced = synced_;
  for (size_t i=0;i<5;++i) result.transactions[i]=transactions_[i];
  result.cutoff = sequence_; result.logCount = logCount_; result.errorCount = errorCount_;
  for (size_t i = 0; i < logCount_; ++i) result.logs[i] = logs_[(logHead_ + i) % 256];
  for (size_t i = 0; i < errorCount_; ++i) result.errors[i] = errors_[(errorHead_ + i) % 32];
  portEXIT_CRITICAL(&mutex_);
}
void DiagnosticStore::purgeThrough(uint64_t sequence) {
  portENTER_CRITICAL(&mutex_);
  for (auto& trace : transactions_) {
    size_t kept=0;
    for(size_t i=0;i<trace.count;++i) if(trace.events[i].sequence>sequence) trace.events[kept++]=trace.events[i];
    trace.count=kept;
    if (!kept) trace.id=0;
  }
  while (logCount_ && logs_[logHead_].sequence <= sequence) { logHead_ = (logHead_ + 1) % 256; --logCount_; }
  while (errorCount_ && errors_[errorHead_].sequence <= sequence) { errorHead_ = (errorHead_ + 1) % 32; --errorCount_; }
  portEXIT_CRITICAL(&mutex_);
}
DiagnosticCounters DiagnosticStore::counters() {
  portENTER_CRITICAL(&mutex_);
  const auto value = counters_;
  portEXIT_CRITICAL(&mutex_);
  return value;
}
void DiagnosticStore::tick(uint32_t now) {
  portENTER_CRITICAL(&mutex_);
  const bool timeout = !startupDone_ && !startupTimedOut_ && uint64_t(esp_timer_get_time()) / 1000 >= 15000;
  const auto stage = startupState_;
  if (timeout) startupTimedOut_ = true;
  portEXIT_CRITICAL(&mutex_);
  if (timeout) {
    count(DiagnosticCounter::StartupTimeout);
    event(EventCode::STARTUP_TIMEOUT, LogLevel::Warn, int32_t(stage));
  }
  portENTER_CRITICAL(&mutex_);
  const bool checkpoint = checkpoint_;
  portEXIT_CRITICAL(&mutex_);
  // Batch failure counters; never write flash from a BLE callback or every loop.
  if (uint32_t(now-lastFlush_) >= (checkpoint ? 10000u : 300000u)) flush();
}
bool DiagnosticStore::flush() {
  lastFlush_ = millis();
  portENTER_CRITICAL(&mutex_);
  const auto value = counters_; const auto generation = generation_; const bool write = dirty_;
  portEXIT_CRITICAL(&mutex_);
  if (!ready_) return false;
  if (!write) return true;
  if (!setPerformanceMode(PerformanceMode::ACTIVE)) return false;
  if (preferences_.putBytes("counters", &value, sizeof(value)) != sizeof(value)) return false;
  portENTER_CRITICAL(&mutex_);
  if (generation == generation_) { dirty_ = false; checkpoint_ = false; }
  portEXIT_CRITICAL(&mutex_);
  return true;
}

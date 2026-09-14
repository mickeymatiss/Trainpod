#include "../diagnostics/SerialLog.h"
#include "MetricsStore.h"
#include "../power/PerformanceMode.h"
#include <Arduino.h>
#include <esp_system.h>
static_assert(sizeof(DeviceMetrics) == 72, "Change the schema version when changing persisted layout");

MetricsStore& MetricsStore::shared() {
  static MetricsStore store;
  return store;
}

void MetricsStore::increment(uint32_t& counter) {
  if (counter != UINT32_MAX) ++counter; // Never wrap a lifetime counter to zero.
  dirty_ = true;
  ++generation_;
}

void MetricsStore::begin() {
  if (begun_) return;
  begun_ = true;
  storageReady_ = preferences_.begin("device_metrics", false);
  if (storageReady_ && preferences_.isKey("aggregate")) {
    DeviceMetrics stored{};
    if (preferences_.getBytesLength("aggregate") == sizeof(stored) &&
        preferences_.getBytes("aggregate", &stored, sizeof(stored)) == sizeof(stored) &&
        stored.version == 1 && stored.startupPending <= 1) {
      metrics_ = stored;
    } else {
      // Do not destroy unknown-version or unreadable data during a downgrade.
      storageReady_ = false;
      preferences_.end();
    }
  }
  if (!storageReady_) WarnLog.println("[METRICS] NVS unavailable/incompatible; using RAM only");
  if (metrics_.startupPending) increment(metrics_.bootDataFailureCount);
  metrics_.startupPending = 1;
  increment(metrics_.bootCount);
  switch (esp_reset_reason()) {
    case ESP_RST_PANIC:
    case ESP_RST_INT_WDT:
    case ESP_RST_TASK_WDT:
    case ESP_RST_WDT:
    case ESP_RST_BROWNOUT:
    case ESP_RST_EFUSE:
    case ESP_RST_PWR_GLITCH:
    case ESP_RST_CPU_LOCKUP:
      recordUnexpectedReset();
      break;
    default: break;
  }
  // One boot checkpoint protects the denominator even in sessions under 5 min.
  flush();
}

void MetricsStore::tick(uint32_t now) {
  if (!outcomeCheckpointAttempted_ && get().startupPending == 0) {
    outcomeCheckpointAttempted_ = true;
    flush(); // At most one early outcome checkpoint per boot, outside BLE callbacks.
    return;
  }
  if (uint32_t(now - lastFlush_) >= FLUSH_INTERVAL_MS) flush();
}

bool MetricsStore::flush() {
  lastFlush_ = millis(); // Failed writes retry at the normal interval, not every loop.
  DeviceMetrics snapshot;
  uint32_t generation;
  portENTER_CRITICAL(&mutex_);
  const bool write = dirty_ && storageReady_;
  snapshot = metrics_;
  generation = generation_;
  portEXIT_CRITICAL(&mutex_);
  if (!write) return storageReady_;
  if (!setPerformanceMode(PerformanceMode::ACTIVE)) return false;
  // NVS atomically replaces one fixed-size blob. No flash access under the lock.
  if (preferences_.putBytes("aggregate", &snapshot, sizeof(snapshot)) != sizeof(snapshot)) {
    WarnLog.println("[METRICS] NVS write failed; retaining dirty RAM counters");
    return false;
  }
  portENTER_CRITICAL(&mutex_);
  if (generation_ == generation) dirty_ = false;
  portEXIT_CRITICAL(&mutex_);
  return true;
}

bool MetricsStore::reset() {
  portENTER_CRITICAL(&mutex_);
  metrics_ = DeviceMetrics{};
  // Do not attribute pre-reset operations or this already-running boot to the
  // new measurement window. The next boot starts startup measurement again.
  bootOutcomeRecorded_ = true;
  outcomeCheckpointAttempted_ = true;
  blePending_ = fetchPending_ = false;
  dirty_ = true;
  ++generation_;
  portEXIT_CRITICAL(&mutex_);
  return flush();
}

DeviceMetrics MetricsStore::get() {
  portENTER_CRITICAL(&mutex_);
  const DeviceMetrics snapshot = metrics_;
  portEXIT_CRITICAL(&mutex_);
  return snapshot;
}

void MetricsStore::recordButtonPress() {
  portENTER_CRITICAL(&mutex_);
  increment(metrics_.buttonPressCount);
  portEXIT_CRITICAL(&mutex_);
}
void MetricsStore::recordUnexpectedReset() {
  portENTER_CRITICAL(&mutex_);
  increment(metrics_.unexpectedResetCount);
  portEXIT_CRITICAL(&mutex_);
}
void MetricsStore::recordBleAttempt() {
  portENTER_CRITICAL(&mutex_);
  if (!blePending_ && metrics_.bleConnectAttempts != UINT32_MAX) {
    increment(metrics_.bleConnectAttempts); blePending_ = true;
  }
  portEXIT_CRITICAL(&mutex_);
}
void MetricsStore::recordFetchAttempt() {
  portENTER_CRITICAL(&mutex_);
  if (!fetchPending_ && metrics_.fetchAttempts != UINT32_MAX) {
    increment(metrics_.fetchAttempts); fetchPending_ = true;
  }
  portEXIT_CRITICAL(&mutex_);
}
void MetricsStore::finishOperation(bool& pending, uint32_t& counter) {
  if (pending) { increment(counter); pending = false; }
}
void MetricsStore::recordBleSuccess() {
  portENTER_CRITICAL(&mutex_);
  finishOperation(blePending_, metrics_.bleConnectSuccesses);
  portEXIT_CRITICAL(&mutex_);
}
void MetricsStore::recordBleFailure() {
  portENTER_CRITICAL(&mutex_);
  finishOperation(blePending_, metrics_.bleConnectFailures);
  portEXIT_CRITICAL(&mutex_);
}
void MetricsStore::recordFetchSuccess() {
  portENTER_CRITICAL(&mutex_);
  finishOperation(fetchPending_, metrics_.fetchSuccesses);
  portEXIT_CRITICAL(&mutex_);
}
void MetricsStore::recordFetchFailure() {
  portENTER_CRITICAL(&mutex_);
  finishOperation(fetchPending_, metrics_.fetchFailures);
  portEXIT_CRITICAL(&mutex_);
}
void MetricsStore::recordBootToData(uint32_t latencyMs) {
  portENTER_CRITICAL(&mutex_);
  if (!bootOutcomeRecorded_) {
    bootOutcomeRecorded_ = true; metrics_.startupPending = 0;
    increment(metrics_.bootDataSuccessCount);
    if (latencyMs < 2000) increment(metrics_.latencyUnder2s);
    else if (latencyMs < 4000) increment(metrics_.latency2To4s);
    else if (latencyMs < 8000) increment(metrics_.latency4To8s);
    else if (latencyMs < 15000) increment(metrics_.latency8To15s);
    else increment(metrics_.latencyOver15s);
  }
  portEXIT_CRITICAL(&mutex_);
}
void MetricsStore::recordBootDataFailure() {
  portENTER_CRITICAL(&mutex_);
  if (!bootOutcomeRecorded_) {
    bootOutcomeRecorded_ = true; metrics_.startupPending = 0;
    increment(metrics_.bootDataFailureCount);
  }
  portEXIT_CRITICAL(&mutex_);
}

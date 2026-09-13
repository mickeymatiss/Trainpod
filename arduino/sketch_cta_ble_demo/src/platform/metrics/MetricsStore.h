#pragma once
#include <stdint.h>
#include <Preferences.h>
#include <freertos/FreeRTOS.h>

struct DeviceMetrics {
  uint32_t version = 1;
  uint32_t bootCount = 0, buttonPressCount = 0;
  uint32_t bootDataSuccessCount = 0, bootDataFailureCount = 0;
  uint32_t latencyUnder2s = 0, latency2To4s = 0, latency4To8s = 0;
  uint32_t latency8To15s = 0, latencyOver15s = 0;
  uint32_t bleConnectAttempts = 0, bleConnectSuccesses = 0, bleConnectFailures = 0;
  uint32_t fetchAttempts = 0, fetchSuccesses = 0, fetchFailures = 0;
  uint32_t unexpectedResetCount = 0;
  // Resolve an interrupted startup on the following boot, without an event log.
  uint32_t startupPending = 0;
};

// RAM event methods may run from BLE callbacks. NVS is touched only by begin/flush/
// tick on the Arduino loop task. Never call flush while holding a BLE mutex.
class MetricsStore {
public:
  static MetricsStore& shared();
  static constexpr uint32_t FLUSH_INTERVAL_MS = 300000;
  void begin();
  void tick(uint32_t now);
  bool flush(); // Save; also call before any future deep sleep/shutdown.
  bool reset(); // Explicit user reset: clear RAM and immediately save to NVS.
  DeviceMetrics get(); // Thread-safe snapshot for future serialization.
  void recordButtonPress();
  void recordBleAttempt();
  void recordBleSuccess();
  void recordBleFailure();
  void recordFetchAttempt();
  void recordFetchSuccess();
  void recordFetchFailure();
  void recordBootToData(uint32_t latencyMs);
  void recordBootDataFailure();
  void recordUnexpectedReset();

private:
  MetricsStore() = default;
  MetricsStore(const MetricsStore&) = delete;
  MetricsStore& operator=(const MetricsStore&) = delete;
  void increment(uint32_t& counter);
  void finishOperation(bool& pending, uint32_t& counter);
  Preferences preferences_;
  DeviceMetrics metrics_{};
  portMUX_TYPE mutex_ = portMUX_INITIALIZER_UNLOCKED;
  bool begun_ = false, storageReady_ = false, dirty_ = false;
  bool bootOutcomeRecorded_ = false, blePending_ = false, fetchPending_ = false;
  bool outcomeCheckpointAttempted_ = false;
  uint32_t generation_ = 0, lastFlush_ = 0;
};

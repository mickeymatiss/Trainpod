#pragma once
#include <stdint.h>

// Generic connected + needs-data policy. Caller serializes access.
class RefreshFlow {
public:
  static constexpr uint32_t DATA_MAX_AGE_MS=60000;
  static constexpr uint32_t RESPONSE_TIMEOUT_MS=5000;
  static constexpr uint32_t SLOW_RETRY_MS=5000;
  // Only a remaining five-second cooldown is meaningful after standby. An old
  // signed deadline can otherwise look billions of milliseconds into the future.
  static uint32_t rearmUpdateDeadlineAfterWake(uint32_t deadline,uint32_t now) {
    return uint32_t(deadline-now)<=SLOW_RETRY_MS ? deadline : now;
  }
  bool hasTransitData() const { return hasData_; }
  uint32_t lastDataReceivedMs() const { return received_; }
  bool stale(uint32_t now) const { return !hasData_ || uint32_t(now-received_)>=DATA_MAX_AGE_MS; }
  bool needsData(uint32_t now) const { return failedDemand_ || stale(now); }
  uint32_t attemptCount() const { return attempts_; }
  bool paused() const { return paused_; }
  void setPaused(bool value) {
    if (paused_ == value) return;
    paused_ = value;
    requested_ = false; attempts_ = 0; failed_ = false;
    // Wake demands new data even if standby lasted less than the freshness threshold.
    if (!value) failedDemand_ = true;
    // Never alter hasData_ or received_ here.
  }
  void onConnected() { requested_=false; attempts_=0; }
  void onDisconnected() {
    if(requested_) { failed_=true; failedDemand_=true; }
    requested_=false; attempts_=0; // No active retry schedule while disconnected.
  }
  void demand() { failedDemand_=true; }
  bool requested() const { return requested_; }
  bool requestRefresh(uint32_t now,bool connected,bool subscribed) {
    if(paused_ || !connected || !subscribed || !needsData(now)) return false;
    if(requested_ && uint32_t(now-lastAttempt_)<RESPONSE_TIMEOUT_MS) return false;
    requested_=true; lastAttempt_=now;
    if(attempts_!=UINT32_MAX) ++attempts_;
    return true;
  }
  void sent(bool success) {
    if(!success) { failed_=true; failedDemand_=true; }
    // A notification enqueue/ACK never changes transit freshness.
  }
  void finish(bool success,uint32_t now) {
    if(success) {
      hasData_=true; received_=now; requested_=false;
      failed_=false; failedDemand_=false; attempts_=0;
    } else {
      failed_=true; failedDemand_=true;
      requested_=false; attempts_=0;
      // The canonical pipeline owns the bounded cooldown before a new episode.
    }
  }
  bool takeFailure() { const bool value=failed_; failed_=false; return value; }
private:
  bool hasData_=false, requested_=false, failed_=false, failedDemand_=false, paused_=false;
  uint32_t received_=0, lastAttempt_=0, attempts_=0;
};

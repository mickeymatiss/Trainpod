#pragma once
#include <stdint.h>

// Transit freshness and request lifetime. Caller serializes access.
class RefreshFlow {
public:
  static constexpr uint32_t DATA_MAX_AGE_MS=60000;
  static constexpr uint32_t REFRESH_TIMEOUT_MS=30000;
  bool hasTransitData() const { return hasData_; }
  uint32_t lastDataReceivedMs() const { return received_; }
  bool stale(uint32_t now) const {
    return !hasData_ || uint32_t(now-received_)>=DATA_MAX_AGE_MS;
  }
  void onConnected() { blocked_=false; }
  void onDisconnected() {
    if(requested_) failed_=true;
    requested_=false;
    blocked_=false;
  }
  bool requested() const { return requested_; }
  bool requestRefresh(uint32_t now,bool connected,bool subscribed) {
    if(!connected || !subscribed || requested_ || blocked_ || !stale(now)) return false;
    requested_=true; blocked_=true; failed_=false; started_=now;
    return true;
  }
  void sent(bool success) { if(!success) finish(false,0); }
  void finish(bool success,uint32_t now) {
    requested_=false; failed_=!success;
    if(success) { hasData_=true; received_=now; blocked_=false; }
    else blocked_=true;
  }
  void poll(uint32_t now) {
    if(requested_ && uint32_t(now-started_)>=REFRESH_TIMEOUT_MS) finish(false,now);
  }
  bool takeFailure() { bool value=failed_; failed_=false; return value; }
private:
  bool hasData_=false, requested_=false, blocked_=false, failed_=false;
  uint32_t received_=0, started_=0;
};

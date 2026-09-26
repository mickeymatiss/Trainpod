#include "../src/products/transit/ble/RefreshFlow.h"
#include <cassert>
#include <cstdio>
int main() {
  RefreshFlow f;
  assert(!f.requestRefresh(0,false,true)); f.onConnected();
  assert(!f.requestRefresh(0,true,false)); assert(f.requestRefresh(10,true,true));
  assert(f.attemptCount()==1); f.sent(true);
  assert(!f.hasTransitData()); assert(!f.requestRefresh(5009,true,true));
  assert(f.requestRefresh(5010,true,true) && f.attemptCount()==2);
  f.sent(false); assert(f.takeFailure() && !f.takeFailure());
  assert(!f.requestRefresh(5011,true,true)); // Enqueue failure does not bypass retry interval.
  f.finish(true,6000); assert(f.hasTransitData() && !f.requested() && f.attemptCount()==0);
  f.onDisconnected(); f.onConnected();
  assert(!f.requestRefresh(65999,true,true)); assert(f.requestRefresh(66000,true,true));
  f.finish(false,67000); assert(f.lastDataReceivedMs()==6000 && f.needsData(67000));
  // Episode cooldown belongs to BleIntegration, not this pure request policy.
  assert(f.requestRefresh(67000,true,true)); f.onDisconnected();
  assert(!f.requested() && f.takeFailure() && f.lastDataReceivedMs()==6000);
  f.finish(true,68000); f.demand(); assert(f.requestRefresh(68001,true,true));
  f.setPaused(true); assert(!f.requested() && !f.requestRefresh(70000,true,true));
  assert(f.lastDataReceivedMs()==68000); f.setPaused(false);
  assert(f.requestRefresh(70001,true,true)); // Wake demands data even if recent.
  RefreshFlow w; const uint32_t start=UINT32_MAX-100;
  w.finish(true,start); assert(!w.requestRefresh(start+59999u,true,true));
  assert(w.requestRefresh(start+60000u,true,true));
  assert(!w.requestRefresh(start+64999u,true,true)); assert(w.requestRefresh(start+65000u,true,true));
  puts("PASS readiness, 5s retry, 60s freshness, demand/pause, failures, retained data and wrap");
}

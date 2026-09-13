#include "../src/products/transit/ble/RefreshFlow.h"
#include <cassert>
#include <cstdio>
int main() {
  RefreshFlow f;
  // Fresh boot, subscription ordering, connection/timer/button overlap.
  assert(!f.requestRefresh(0,false,true));
  f.onConnected();
  assert(!f.requestRefresh(0,true,false));
  assert(f.requestRefresh(10,true,true));
  for(uint32_t t=11;t<100;++t) assert(!f.requestRefresh(t,true,true));
  f.sent(true);
  assert(!f.hasTransitData() && f.lastDataReceivedMs()==0);
  f.finish(true,100);
  assert(f.hasTransitData() && f.lastDataReceivedMs()==100 && !f.requested());
  // Reconnect with fresh data.
  f.onDisconnected(); f.onConnected();
  assert(!f.requestRefresh(45100,true,true));
  assert(f.lastDataReceivedMs()==100);
  // Continuously connected, exact 60-second boundary.
  assert(!f.requestRefresh(60099,true,true));
  assert(f.requestRefresh(60100,true,true));
  assert(!f.requestRefresh(60101,true,true));
  assert(f.lastDataReceivedMs()==100);
  f.finish(true,61000);
  // Stale reconnect, then timeout retains data and suppresses hot retries.
  f.onDisconnected(); f.onConnected();
  assert(f.requestRefresh(200000,true,true));
  f.poll(229999); assert(f.requested());
  f.poll(230000);
  assert(!f.requested() && f.takeFailure() && f.hasTransitData());
  assert(f.lastDataReceivedMs()==61000);
  for(uint32_t t=230000;t<500000;t+=100) assert(!f.requestRefresh(t,true,true));
  // Reconnect is a deliberate next opportunity.
  f.onDisconnected(); f.onConnected();
  assert(f.requestRefresh(500000,true,true));
  f.sent(false); assert(f.takeFailure() && !f.requestRefresh(500001,true,true));
  assert(f.lastDataReceivedMs()==61000);
  // Disconnect clears in-flight, not freshness.
  f.onDisconnected(); f.onConnected(); assert(f.requestRefresh(500100,true,true));
  f.onDisconnected(); assert(!f.requested() && f.lastDataReceivedMs()==61000);
  // Fresh manual/late valid payload also resets freshness and retry gating.
  f.finish(true,510000); assert(!f.requestRefresh(510001,true,true));
  // Unsigned freshness and timeout calculations survive wrap.
  RefreshFlow w;
  w.finish(true,0xfffffff0u);
  assert(!w.requestRefresh(uint32_t(0xfffffff0u+59999u),true,true));
  assert(w.requestRefresh(uint32_t(0xfffffff0u+60000u),true,true));
  w.poll(uint32_t(0xfffffff0u+90000u)); assert(!w.requested() && w.takeFailure());
  RefreshFlow empty;
  empty.onConnected(); assert(empty.requestRefresh(0xfffffff0u,true,true));
  empty.poll(uint32_t(0xfffffff0u+30000u)); assert(empty.takeFailure());
  assert(!empty.hasTransitData() && !empty.requestRefresh(100000,true,true));
  puts("PASS: boot, fresh/stale reconnect, 60-second boundary, duplicate suppression, success-only timestamp, disconnect, timeout, no retry loop, rollover.");
}

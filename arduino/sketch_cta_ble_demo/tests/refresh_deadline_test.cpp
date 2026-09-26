#include "../src/products/transit/ble/RefreshFlow.h"
#include <cassert>
#include <cstdio>

// This is the unchanged comparison at the episode/session admission boundary.
static bool due(uint32_t now,uint32_t deadline) { return int32_t(now-deadline)>=0; }
int main() {
  static_assert(RefreshFlow::SLOW_RETRY_MS==5000);
  static_assert(RefreshFlow::DATA_MAX_AGE_MS==60000);
  static_assert(RefreshFlow::RESPONSE_TIMEOUT_MS==5000);
  const auto rearm=RefreshFlow::rearmUpdateDeadlineAfterWake;
  assert(!due(5099,5100) && due(5100,5100));
  assert(rearm(5100,200)==5100); // Short standby preserves the outstanding cooldown.
  assert(rearm(5100,5099)==5100 && !due(5099,rearm(5100,5099)));
  assert(due(5100,rearm(5100,5100)));
  assert(due(100000,rearm(5100,100000))); // Ordinary expired deadline.
  const uint32_t start=UINT32_MAX-2000u, wrapped=start+5000u;
  assert(!due(start+4999u,wrapped) && due(start+5000u,wrapped));
  assert(rearm(wrapped,start+1000u)==wrapped);
  assert(due(start+6000u,rearm(wrapped,start+6000u)));
  const uint32_t deadline=5100u;
  const uint32_t shortStandby=deadline+0x7fffffffu;
  assert(due(shortStandby,deadline));
  assert(due(shortStandby,rearm(deadline,shortStandby)));
  const uint32_t longStandby=deadline+0x80001000u;
  assert(!due(longStandby,deadline)); // Characterizes the pre-fix failure.
  const uint32_t awakened=rearm(deadline,longStandby);
  assert(awakened==longStandby && due(longStandby,awakened));
  assert(!due(longStandby,0)); // Zero is not an immediate deadline at long uptime.
  assert(due(longStandby,longStandby)); // Existing wake now rearms the session at now.
  const uint32_t next=longStandby+RefreshFlow::SLOW_RETRY_MS;
  assert(!due(longStandby+4999u,next) && due(longStandby+5000u,next));
  assert(rearm(next,longStandby+1000u)==next); // Another short sleep cannot bypass retry.
  RefreshFlow flow;
  flow.finish(true,100); flow.setPaused(true); flow.setPaused(false);
  assert(flow.needsData(longStandby));
  assert(flow.requestRefresh(longStandby,true,true));
  flow.finish(true,longStandby);
  assert(!flow.needsData(longStandby+59999u) && flow.needsData(longStandby+60000u));
  puts("PASS episode deadline before/wrap/half-range/long standby, wake rearm, retained cooldown, subsequent retry/freshness");
}

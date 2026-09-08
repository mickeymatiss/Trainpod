#include "../TransitTextBuffer.h"
#include <cassert>
#include <string>
#include <cstdio>
int main() {
  TransitTextBuffer b;
  std::string payload="Morgan|West|Pink:E27EA6:1,3|Loop|Pink:E27EA6:8";
  uint64_t now=100;
  for(size_t i=0;i<payload.size();i+=7) {
    b.accept(reinterpret_cast<const uint8_t*>(payload.data()+i),
             (payload.size()-i<7 ? payload.size()-i : 7),now);
    assert(!b.ready(now)); now+=1000;
  }
  assert(!b.ready(now+248999));
  assert(b.ready(now+249000) && !b.invalid());
  assert(payload==b.text());
  b.reset(); assert(!b.ready(now+1000000));
  std::string maximum(2048,'x');
  b.accept(reinterpret_cast<const uint8_t*>(maximum.data()),maximum.size(),now);
  assert(!b.invalid() && maximum==b.text());
  uint8_t extra='x'; b.accept(&extra,1,now);
  assert(b.invalid() && b.ready(now+250000));
  b.reset();
  const uint8_t nul[]={65,0,66};
  b.accept(nul,sizeof(nul),now); assert(b.invalid());
  b.reset(); b.accept(reinterpret_cast<const uint8_t*>(payload.data()),payload.size(),now);
  assert(!b.invalid() && payload==b.text());
  puts("PASS: transit fragmentation, idle boundary, reset, size bound, NUL rejection, recovery.");
}

#pragma once
#include <string>
#include <cstdint>
#include <cstdio>
// Independent fixture footer helper, not a replacement decoder.
inline std::string complete(const std::string& body) {
  uint32_t hash=2166136261u;
  for(unsigned char c:body) { hash^=c; hash*=16777619u; }
  char footer[40]; std::snprintf(footer,sizeof(footer),"END\t%zu\t%08X\n",body.size(),hash);
  return body+footer;
}

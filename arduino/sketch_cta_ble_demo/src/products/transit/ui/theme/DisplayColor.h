#pragma once
#include <stdint.h>
#include "../../../../../FirmwareConfig.h"
#if KEYTRAIN_COLOR_CORRECTION
#include "CompactCorrection.h"
#endif
namespace DisplayColor {
// Renderer-owned cache. Never call from BLE/NVS tasks; source RGB stays unchanged.
inline uint32_t corrected(uint32_t rgb) {
#if KEYTRAIN_COLOR_CORRECTION
  struct Entry { uint32_t input, output; };
  static Entry cache[64];
  static unsigned count=0,next=0;
  for(unsigned i=0;i<count;++i) if(cache[i].input==rgb) return cache[i].output;
  const uint32_t result=compact_colorscape::correct(rgb);
  cache[next]={rgb,result};next=(next+1)%64;if(count<64) ++count;
  return result;
#else
  return rgb;
#endif
}
inline uint16_t rgb565(uint32_t rgb) {
  const uint32_t c=corrected(rgb);
  return uint16_t(((c>>8)&0xF800)|((c>>5)&0x07E0)|((c>>3)&0x001F));
}
}

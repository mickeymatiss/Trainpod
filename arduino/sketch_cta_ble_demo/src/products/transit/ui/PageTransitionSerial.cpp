#include "ArrivalScreen.h"
#include "../../../platform/diagnostics/SerialLog.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>

bool ArrivalScreen::transitionCommand(const char* command,uint32_t now) {
  if(std::strcmp(command,"transition") && std::strncmp(command,"transition ",11)) return false;
  auto& s=platformDip.settings;
  if(!std::strcmp(command,"transition on")) s.enabled=true;
  else if(!std::strcmp(command,"transition off")) {
    s.enabled=false;
    if(platformDip.active && !suspended) animatePlatform(now);
  } else if(std::strcmp(command,"transition") && std::strcmp(command,"transition status") && std::strcmp(command,"transition help")) {
    char key[16],arg[16],extra;
    bool matched=false;
    if(std::sscanf(command,"transition %15s %15s %c",key,arg,&extra)==2) {
      struct Tuner { const char* name;int* field;int low,high; };
      const Tuner tuners[]={{"outms",&s.outMs,40,200},{"inms",&s.inMs,40,250},
        {"stagger",&s.stagger,0,80},{"gap",&s.gap,0,80}};
      for(const auto& tuner:tuners) if(!std::strcmp(key,tuner.name)) {
        char* end=nullptr;
        const long value=std::strtol(arg,&end,10);
        if(end==arg || *end || value<tuner.low || value>tuner.high) {
          InfoLog.printf("ERR transition %s range = %d..%d\n",key,tuner.low,tuner.high);
          return true;
        }
        *tuner.field=int(value);matched=true;break;
      }
    }
    if(!matched) { InfoLog.println("ERR transition: use status, on, off, outms, inms, stagger, gap");return true; }
  }
  const int fieldsDuration=s.outMs+s.gap+s.inMs;
  const int contentDuration=s.outMs+s.gap+int(platformDip.arrivalSlots*PlatformDip::ROW_IN_MS);
  InfoLog.printf("OK transition %s outms=%d inms=%d stagger=%d gap=%d lightin=%lums total=%dms active=%d\n",
    s.enabled?"on":"off",s.outMs,s.inMs,s.stagger,s.gap,(unsigned long)PlatformDip::LIGHT_IN_MS,
    s.enabled ? (fieldsDuration>contentDuration ? fieldsDuration : contentDuration) : 0,platformDip.active);
  InfoLog.println("Incoming sequence: one arrival cell at a time, all fields together, 150ms each. Total is nominal; late frames extend it. Stagger setting unused in this experiment.");
  if(!std::strcmp(command,"transition help"))
    InfoLog.println("transition outms 40..200 | inms 40..250 | stagger 0..80 | gap 0..80. RAM-only; timing edits apply on next transition.");
  return true;
}

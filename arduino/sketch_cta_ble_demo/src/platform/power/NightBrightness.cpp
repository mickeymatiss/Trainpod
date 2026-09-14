#include "../diagnostics/SerialLog.h"
#include "NightBrightness.h"
#include <esp_timer.h>
#include <algorithm>
#include <cstring>
#include <cstdio>
#include <cstdlib>

NightBrightness& NightBrightness::shared() { static NightBrightness instance; return instance; }

void NightBrightness::sync(uint64_t unixMs,int offsetMinutes,uint32_t session) {
  if(unixMs<1577836800000ULL || unixMs>4102444800000ULL || !session || offsetMinutes < -720 || offsetMinutes > 840) return;
  const uint64_t now=uint64_t(esp_timer_get_time())/1000;
  portENTER_CRITICAL(&mutex_);
  localMs_=int64_t(unixMs)+int64_t(offsetMinutes)*60000;
  syncedAt_=now; known_=true;
  portEXIT_CRITICAL(&mutex_);
}

int NightBrightness::localMinute() {
  const uint64_t now=uint64_t(esp_timer_get_time())/1000;
  portENTER_CRITICAL(&mutex_);
  const uint64_t elapsed=now-syncedAt_,local=localMs_;
  const bool valid=known_ && elapsed<24ULL*60*60*1000;
  portEXIT_CRITICAL(&mutex_);
  return valid ? int(((local+elapsed)/60000)%1440) : -1;
}

uint8_t NightBrightness::activeLevel() {
  const int minute=localMinute();
  if(minute<0) return std::min(day_,night_);
  const int hour=minute/60;
  // Equal hours deliberately means night all day; supports crossing midnight.
  const bool night=start_==end_ || (start_<end_ ? hour>=start_ && hour<end_ : hour>=start_ || hour<end_);
  return night ? std::min(day_,night_) : day_;
}

bool NightBrightness::command(const char* line) {
  if(std::strcmp(line,"night") && std::strncmp(line,"night ",6)) return false;
  if(!std::strcmp(line,"night reset")) { day_=PowerConfig::ACTIVE_BRIGHTNESS;night_=50;start_=22;end_=7; }
  else if(std::strcmp(line,"night") && std::strcmp(line,"night status") && std::strcmp(line,"night help")) {
    char key[16],arg[16],extra;
    if(std::sscanf(line,"night %15s %15s %c",key,arg,&extra)!=2) { InfoLog.println("ERR night command; type night help"); return true; }
    int* field=nullptr; int maximum=255;
    if(!std::strcmp(key,"brightness")) field=&night_;
    else if(!std::strcmp(key,"day")) field=&day_;
    else if(!std::strcmp(key,"start")) { field=&start_;maximum=23; }
    else if(!std::strcmp(key,"end")) { field=&end_;maximum=23; }
    char* end; const long value=std::strtol(arg,&end,10);
    if(!field) { InfoLog.println("ERR night command; type night help"); return true; }
    if(*end || value<0 || value>maximum) { InfoLog.printf("ERR night %s range = 0..%d\n",key,maximum); return true; }
    *field=int(value);
  }
  const int minute=localMinute();
  InfoLog.printf("OK night day=%d brightness=%d start=%d end=%d target=%u time=",day_,night_,start_,end_,activeLevel());
  if(minute<0) InfoLog.println("unknown (night cap)");
  else InfoLog.printf("%02d:%02d\n",minute/60,minute%60);
  if(!std::strcmp(line,"night help")) InfoLog.println("night status | night reset | night brightness 0..255 | night day 0..255 | night start 0..23 | night end 0..23. Local hours, end exclusive; equal hours = always night. RAM only.");
  return true;
}

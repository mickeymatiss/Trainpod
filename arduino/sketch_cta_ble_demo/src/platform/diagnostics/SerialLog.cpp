#include "SerialLog.h"
#include <atomic>
#include <cstring>
#include <freertos/semphr.h>

SerialLog DebugLog(SerialLog::Level::Debug),InfoLog(SerialLog::Level::Info),WarnLog(SerialLog::Level::Warn);
static std::atomic<bool> debugEnabled{false};

size_t SerialLog::write(const uint8_t* data,size_t size) {
  static SemaphoreHandle_t mutex=xSemaphoreCreateMutex();
  if(!mutex) return size;
  xSemaphoreTake(mutex,portMAX_DELAY);
  if(level_==Level::Debug && !debugEnabled.load()) { lineStart_=true; xSemaphoreGive(mutex); return size; }
  size_t start=0;
  while(start<size) {
    if(lineStart_) Serial.print(level_==Level::Debug ? "[DEBUG] " : level_==Level::Info ? "[INFO] " : "[WARN] ");
    size_t end=start;
    while(end<size && data[end]!='\n') ++end;
    const bool newline=end<size;
    if(newline) ++end;
    Serial.write(data+start,end-start);
    lineStart_=newline;
    start=end;
  }
  xSemaphoreGive(mutex);
  return size;
}

bool SerialLog::command(const char* line) {
  if(std::strcmp(line,"log") && std::strncmp(line,"log ",4)) return false;
  if(!std::strcmp(line,"log info")) debugEnabled=false;
  else if(!std::strcmp(line,"log debug")) debugEnabled=true;
  else if(std::strcmp(line,"log") && std::strcmp(line,"log status") && std::strcmp(line,"log help")) {
    InfoLog.println("ERR log level: use log info or log debug"); return true;
  }
  InfoLog.printf("OK log = %s\n",debugEnabled.load()?"debug":"info");
  if(!std::strcmp(line,"log help")) InfoLog.println("log info (default, keeps warnings) | log debug | log status. RAM only; serial responses always visible.");
  return true;
}

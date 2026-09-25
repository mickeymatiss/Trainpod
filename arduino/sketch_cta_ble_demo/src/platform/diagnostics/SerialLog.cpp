#include "SerialLog.h"
#include <atomic>
#include <cstring>
#include <algorithm>
#include <freertos/semphr.h>
#include <freertos/queue.h>
#include <freertos/task.h>

SerialLog DebugLog(SerialLog::Level::Debug),InfoLog(SerialLog::Level::Info),WarnLog(SerialLog::Level::Warn);
static std::atomic<bool> debugEnabled{false};

namespace {
struct DeferredLog { SerialLog::Level level; uint16_t length; uint8_t data[192]; };
QueueHandle_t deferredLogs=nullptr;
std::atomic<TaskHandle_t> deferredTask{nullptr};
std::atomic<uint32_t> droppedDeferred{0};
}
bool SerialLog::beginDeferred() {
  deferredLogs=xQueueCreate(16,sizeof(DeferredLog));
  return deferredLogs!=nullptr;
}
void SerialLog::deferCurrentTask() { deferredTask.store(xTaskGetCurrentTaskHandle()); }
void SerialLog::drainDeferred() {
  DeferredLog record;
  for(int i=0;deferredLogs && i<4 && xQueueReceive(deferredLogs,&record,0)==pdTRUE;++i) {
    auto& log=record.level==Level::Warn ? WarnLog : record.level==Level::Info ? InfoLog : DebugLog;
    log.write(record.data,record.length);
  }
  const auto lost=droppedDeferred.exchange(0);
  if(lost) WarnLog.printf("[RENDER] Dropped %lu diagnostic fragments\n",(unsigned long)lost);
}

size_t SerialLog::write(const uint8_t* data,size_t size) {
  if(deferredTask.load()==xTaskGetCurrentTaskHandle()) {
    if(level_==Level::Debug && !debugEnabled.load()) return size;
    for(size_t offset=0;offset<size;) {
      DeferredLog record; record.level=level_;
      record.length=std::min(size-offset,sizeof(record.data));
      memcpy(record.data,data+offset,record.length); offset+=record.length;
      if(!deferredLogs || xQueueSend(deferredLogs,&record,0)!=pdTRUE) ++droppedDeferred;
    }
    return size;
  }
  static SemaphoreHandle_t mutex=xSemaphoreCreateMutex();
  // Logs may be dropped under contention; application/BLE work must proceed.
  if(!mutex || xSemaphoreTake(mutex,0)!=pdTRUE) return size;
  if(level_==Level::Debug && !debugEnabled.load()) { lineStart_=true; xSemaphoreGive(mutex); return size; }
  size_t start=0;
  while(start<size) {
    size_t end=start;
    while(end<size && data[end]!='\n') ++end;
    const bool newline=end<size;
    if(newline) ++end;
    const char* prefix=level_==Level::Debug ? "[DEBUG] " : level_==Level::Info ? "[INFO] " : "[WARN] ";
    const size_t needed=end-start+(lineStart_ ? std::strlen(prefix) : 0);
    if(size_t(std::max(0,Serial.availableForWrite()))<needed) {
      lineStart_=true;
      break; // No waiting, retries, or flush when the USB host is not reading.
    }
    if(lineStart_) Serial.print(prefix);
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

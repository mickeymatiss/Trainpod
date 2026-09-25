#include "DisplayController.h"
#include "ArrivalScreen.h"
#include "DisplayMode.h"
#include "../../../platform/device/DeviceHardware.h"
#include "../../../platform/setup/DeviceProvisioning.h"
#include "../../../platform/power/PerformanceMode.h"
#include "../../../platform/diagnostics/SerialLog.h"
#include "../../../platform/diagnostics/DiagnosticStore.h"
#include "../../../platform/metrics/MetricsStore.h"
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <freertos/queue.h>
#include <atomic>
#include <cstring>
#include <cstdio>
#include <esp_timer.h>

namespace {
constexpr uint32_t RenderDeadlineMs=5000;
// SPSC triple buffer: front belongs to worker, back to app, middle is replaceable.
// Only the slot index crosses tasks. Never memcpy std::string through a queue,
// copy strings under a lock, or let the producer touch the worker's front slot.
RenderSnapshot slots[3];
std::atomic<unsigned> middle{1};
unsigned back=2,front=0;
constexpr unsigned Pending=4;
RenderSnapshot current; // Authoritative application state; app loop only.
uint32_t generation=0,suspendedAt=0,disconnectedAt=0;
bool dirty=true,warningRequested=false,started=false;
bool rendererAttempted=false,rendererQueuesReady=false;
TaskHandle_t worker=nullptr;
struct Command { char text[32]; };
QueueHandle_t commands=nullptr;
bool serialHeld=false; // Application-owned debug hold; physical edges clear it.
std::atomic<bool> injectedStall{false}, injectedFailure{false};
std::atomic<uint32_t> injectedDelay{0};
// These are atomics so even a permanently blocked driver leaves inspectable state.
std::atomic<uint32_t> activeOperation{0},activeGeneration{0},activeStarted{0},activePage{0};
uint32_t reportedStall=0; // App-owned.

bool takeSnapshot() {
  if(!(middle.load(std::memory_order_acquire)&Pending)) return false;
  front=middle.exchange(front,std::memory_order_acq_rel)&3;
  return true;
}
void drawSetup(Arduino_GFX& gfx,int state) {
  gfx.fillScreen(pallete::background());gfx.setFont(nullptr);gfx.setTextWrap(false);
  gfx.setTextColor(pallete::primaryText());gfx.setTextSize(3);gfx.setCursor(22,30);gfx.print("SET UP");
  gfx.setTextSize(2);gfx.setCursor(22,80);gfx.print("Open TrainPod app");
  gfx.setCursor(22,117);
  gfx.print(state==DeviceProvisioning::StorageError ? "Storage error" :
    state==DeviceProvisioning::SetupReady ? "Ready to connect" : "Press button");
}
void renderTask(void*) {
  SerialLog::deferCurrentTask(); // No renderer ever waits for the app's Serial mutex.
  auto& gfx=*deviceDisplay();
  static ArrivalScreen screen(gfx); // Large caches do not live on the task stack.
  bool initialized=false,working=false,failed=false,wasSetup=true;
  uint32_t operation=0,startedAt=0;
  auto finish=[&](const char* error) {
    const auto& snapshot=slots[front];
    const auto elapsed=uint32_t(millis()-startedAt);
    if(error && !std::strcmp(error,"superseded")) {
      InfoLog.printf("RENDER_SUPERSEDED generation=%lu elapsed=%lums\n",
        (unsigned long)snapshot.generation,(unsigned long)elapsed);
    } else if(error) {
      WarnLog.printf("RENDER_FAILED generation=%lu error=%s elapsed=%lums page=%u setup=%d\n",
        (unsigned long)snapshot.generation,error,(unsigned long)elapsed,unsigned(snapshot.board.page),snapshot.setupState);
      screen.invalidate(); failed=true;
    } else {
      InfoLog.printf("RENDER_COMPLETE generation=%lu elapsed=%lums page=%u\n",
        (unsigned long)snapshot.generation,(unsigned long)elapsed,unsigned(snapshot.board.page));
      if(snapshot.transaction) DiagnosticStore::shared().event(EventCode::DISPLAY_UPDATED,
        LogLevel::Info,elapsed,0,snapshot.transaction);
    }
    activeOperation.store(0,std::memory_order_release); working=false;
  };
  for(;;) {
    // Close an obsolete operation before releasing its owned snapshot slot.
    if(middle.load(std::memory_order_acquire)&Pending) {
      if(working) finish("superseded");
      if(takeSnapshot()) {
        const auto& snapshot=slots[front];
        failed=false;working=true;startedAt=millis();
        activeStarted=startedAt;activeGeneration=snapshot.generation;activePage=snapshot.board.page;
        if(++operation==0) ++operation;
        activeOperation.store(operation,std::memory_order_release);
        InfoLog.printf("RENDER_BEGIN generation=%lu t=%lu page=%u setup=%d\n",
          (unsigned long)snapshot.generation,(unsigned long)startedAt,unsigned(snapshot.board.page),snapshot.setupState);
        // Fault injection is deliberately confined to this task and holds no app lock.
        const auto delayMs=injectedDelay.load();
        const auto delayStarted=millis();
        while(injectedStall.load() || uint32_t(millis()-delayStarted)<delayMs) vTaskDelay(pdMS_TO_TICKS(20));
        if(injectedFailure.exchange(false)) finish("injected failure");
        else if(uint32_t(millis()-startedAt)>=RenderDeadlineMs) finish("timeout");
        else {
          if(!initialized) {
            initialized=gfx.begin();
            if(initialized) gfx.setRotation(1);
          }
          if(!initialized) finish("LCD initialization");
          else {
            pallete::setRenderTheme(snapshot.theme);
            if(snapshot.setupState>=0) {
              drawSetup(gfx,snapshot.setupState);wasSetup=true;
            } else {
              if(wasSetup) screen.invalidate();
              wasSetup=false;
              screen.applySnapshot(snapshot,millis());
            }
          }
        }
      }
    }
    if(working && !failed) {
      const auto& snapshot=slots[front];
      if(uint32_t(millis()-startedAt)>=RenderDeadlineMs) finish("timeout");
      else {
        Command command;
        if(snapshot.setupState<0 && xQueueReceive(commands,&command,0)==pdTRUE)
          screen.effectsCommand(command.text,millis());
        if(snapshot.setupState<0) screen.tick(millis());
        if(snapshot.setupState<0 && screen.error()) finish(screen.error());
        else if(uint32_t(millis()-startedAt)>=RenderDeadlineMs) finish("timeout");
        else if(snapshot.setupState>=0 || (!screen.pending() && !uxQueueMessagesWaiting(commands))) finish(nullptr);
      }
    }
    // Lowest priority + regular yield: BLE, app loop and idle watchdog all run,
    // including on a single-core C6. No task is force-deleted while owning SPI.
    vTaskDelay(pdMS_TO_TICKS(16));
  }
}
}
namespace DisplayController {
void begin() {
  if(started) return;
  started=true;
  current.board.compact=DisplayMode::compact();
  current.board.clockAdvanced=current.board.pageStarted=millis();
  current.theme=pallete::theme();
  pinDisplayPerformance();
  commands=xQueueCreate(4,sizeof(Command));
  rendererQueuesReady=commands && SerialLog::beginDeferred();
  requestRender();
}
void startRenderer() {
  if(!started || rendererAttempted) return;
  rendererAttempted=true;
  InfoLog.println("[BOOT] First BLE poll complete; starting renderer");
  if(!rendererQueuesReady ||
      xTaskCreate(renderTask,"TrainPodRender",16384,nullptr,tskIDLE_PRIORITY,&worker)!=pdPASS) {
    worker=nullptr;
    WarnLog.println("RENDER_FAILED generation=0 error=worker allocation; transit continues");
  }
}
uint32_t requestRender(uint64_t transaction) {
  current.generation=++generation;current.transaction=transaction;
  current.theme=pallete::theme();
  slots[back]=current;
  back=middle.exchange(back|Pending,std::memory_order_acq_rel)&3;
  dirty=false;
  if(rendererAttempted && !worker) WarnLog.printf("RENDER_FAILED generation=%lu error=worker unavailable\n",(unsigned long)generation);
  return generation;
}
void setSetupState(int value) { if(current.setupState!=value) { current.setupState=value;dirty=true; } }
void setPlatforms(const ArrivalBoard& board,uint32_t now) {
  const bool first=!current.board.hasData;
  current.board.setBoard(board,now);dirty=true;
  if(first) {
    DiagnosticStore::shared().startupComplete();
    const uint64_t ms=esp_timer_get_time()/1000;
    MetricsStore::shared().recordBootToData(ms>UINT32_MAX ? UINT32_MAX : uint32_t(ms));
  }
}
void nextPlatform(uint32_t now) { current.board.nextPlatform(now);dirty=true; }
void nextStation(uint32_t now) { current.board.nextStation(now);dirty=true; }
void setConnected(bool value) {
  if(current.connected==value) return;
  current.connected=value;disconnectedAt=millis();warningRequested=false;dirty=true;
}
void buttonChanged(bool value,uint32_t) { current.buttonDown=value;serialHeld=false;dirty=true; }
bool feedbackHeld() { return serialHeld; }
void themeChanged(uint32_t now) {
  ++current.styleRevision;
  if(current.board.compact!=DisplayMode::compact()) {
    current.board.compact=DisplayMode::compact();current.board.page=0;current.board.pageStarted=now;
  }
  dirty=true;
}
void suspend(uint32_t now) {
  if(current.suspended) return;
  current.suspended=true;suspendedAt=now;dirty=true;
}
void resume(uint32_t now) {
  if(!current.suspended) return;
  current.suspended=false;current.board.pageStarted+=now-suspendedAt;
  current.board.clockAdvanced+=now-suspendedAt;dirty=true;
}
void tick(uint32_t now) {
  SerialLog::drainDeferred();
  const auto op=activeOperation.load(std::memory_order_acquire);
  const auto began=activeStarted.load(),gen=activeGeneration.load(),page=activePage.load();
  const uint32_t observedNow=millis();
  if(op && op!=reportedStall && op==activeOperation.load(std::memory_order_acquire) && uint32_t(observedNow-began)>=RenderDeadlineMs) {
    reportedStall=op;
    WarnLog.printf("RENDER_FAILED generation=%lu error=stall elapsed=%lums page=%lu; app continues\n",
      (unsigned long)gen,(unsigned long)(observedNow-began),(unsigned long)page);
  }
  if(current.setupState<0 && !current.suspended && current.board.tick(now)) dirty=true;
  if(!current.connected && !warningRequested && uint32_t(now-disconnectedAt)>=30000) {
    warningRequested=true;dirty=true;
  }
  if(dirty) requestRender();
}
bool command(const char* text) {
  if(!std::strncmp(text,"render",6) && (text[6]==0 || text[6]==' ')) {
    unsigned delay;char extra;
    if(!std::strcmp(text,"render fail")) injectedFailure=true;
    else if(!std::strcmp(text,"render stall")) injectedStall=true;
    else if(!std::strcmp(text,"render resume")) { injectedStall=false;injectedDelay=0; }
    else if(std::sscanf(text,"render slow %u %c",&delay,&extra)==1 && delay<=60000) injectedDelay=delay;
    else { InfoLog.println("render slow 0..60000 | render fail | render stall | render resume");return true; }
    dirty=true;InfoLog.printf("OK %s\n",text);return true;
  }
  // Preserve normal BLE/metrics/night command routing. UI commands alone go to worker.
  char group[16]={};std::sscanf(text,"%15s",group);
  const char* names[]={"help","status","reset","demo","all","lip","depth","bezel","spring","stable","bloom","transition"};
  bool recognized=false;for(const auto* name:names) recognized|=!std::strcmp(group,name);
  if(!recognized) return false;
  Command command{};std::strncpy(command.text,text,sizeof(command.text)-1);
  if(!worker || xQueueSend(commands,&command,0)!=pdTRUE) WarnLog.println("UI command unavailable/busy");
  else {
    if(!std::strcmp(text,"spring testdown")) serialHeld=true;
    if(!std::strcmp(text,"spring testup") || !std::strcmp(text,"spring off") ||
       !std::strcmp(text,"spring reset") || !std::strcmp(text,"reset") ||
       !std::strcmp(text,"all off") || !std::strncmp(text,"demo ",5)) serialHeld=false;
    dirty=true;
  }
  return true;
}
}

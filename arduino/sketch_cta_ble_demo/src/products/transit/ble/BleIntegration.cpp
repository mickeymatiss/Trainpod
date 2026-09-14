#include "../../../platform/diagnostics/SerialLog.h"
#include <Arduino.h>
#include <NimBLEDevice.h>
#include <esp_timer.h>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>
#include <freertos/queue.h>
#include "../../../platform/transport/BLETestReceiver.h"
#include "../../../platform/ble/BleSession.h"
#include "BleIntegration.h"
#include "RefreshFlow.h"
#include "../ui/theme/pallete.h"
#include "../../../platform/transport/PayloadDelivery.h"
#include "../../../platform/metrics/MetricsStore.h"
#include "../../../platform/diagnostics/DiagnosticStore.h"
static RefreshFlow refreshFlow;
extern bool handleUiSerialCommand(const char* command);
static void (*uiColorChanged)() = nullptr;
// Atomic ATT command (19 bytes): UC:1234ABCD:#RRGGBB.
// ACK: UA:1234ABCD:#RRGGBB; errors E1 invalid, E2 storage, E3 busy.
struct UiColorRequest {
  uint32_t token; uint32_t rgb; uint32_t session; bool valid;
  bool isTheme; pallete::Theme theme;
};
static pallete::Theme incomingTheme{};
static uint32_t themeToken = 0, themeStartedMs = 0;
static uint8_t themeMask = 0;
static QueueHandle_t colorRequests;
static uint32_t connectionSession = 0;
static bool parseHex(const uint8_t* text, size_t length, uint32_t& value) {
  value = 0;
  for (size_t i = 0; i < length; ++i) {
    const uint8_t c = text[i];
    const int digit = c >= '0' && c <= '9' ? c-'0' :
      c >= 'A' && c <= 'F' ? c-'A'+10 : c >= 'a' && c <= 'f' ? c-'a'+10 : -1;
    if (digit < 0) return false;
    value = (value << 4) | digit;
  }
  return true;
}

// One episode spans NEED_DATA retries; the first terminal result wins.
// Keep a failed episode open until data arrives, disconnect, or standby, so
// repeated lower-level failures cannot inflate either attempts or outcomes.
static bool fetchEpisode = false;
static void failFetchEpisode() {
  if (!fetchEpisode) return;
  MetricsStore::shared().recordFetchFailure();
  MetricsStore::shared().recordBootDataFailure();
}
static void (*refreshStarted)()=nullptr;
static bool e2eConnected=false, e2eDisconnected=false, e2eReceiving=false;
static bool sawRefreshBytes=false;


static uint8_t wireMode=0; // 0 unknown, 1 SLIP test, 2 legacy transit text
#include "../../../platform/transport/IdleTextBuffer.h"
static IdleTextBuffer transitText;


const char* DEVICE_NAME = "CTA Tracker";
const char* SERVICE_UUID = "7A1C0001-8F4A-4D2B-9A57-1C2D3E4F5001";
const char* CHARACTERISTIC_UUID = "7A1C0002-8F4A-4D2B-9A57-1C2D3E4F5001";
SemaphoreHandle_t receiverMutex;
QueueHandle_t reports;
QueueHandle_t rawWrites;
uint64_t droppedLogs=0;
uint64_t droppedRawLogs=0;
volatile bool rawLogging=true;
static BleSession* bleSession=nullptr;
static uint32_t nextSessionAttemptMs=0;
static bool sessionWasActive=false;
static PayloadDelivery::Frame deliveryFrame;
static uint32_t requestSequence=0, transactionBoot=0, connectionFirstRequest=1;
static uint64_t latestRequest=0, lastApplied=0;
static void receiveFailure(uint64_t tx, uint8_t error) {
  DiagnosticStore::shared().event(EventCode::RESPONSE_RX_FAILED,LogLevel::Warn,error,deliveryFrame.bytes,tx);
}


static void colorAck(uint32_t token, const char* result) {
  char ack[24];
  const int length = snprintf(ack, sizeof(ack), "UA:%08lX:%s", (unsigned long)token, result);
  if (bleSession && bleSession->isReady())
    bleSession->characteristic()->notify(reinterpret_cast<const uint8_t*>(ack), length, bleSession->peer());
}

static void themeAck(uint32_t token, const char* result) {
  char ack[24];
  const int length = snprintf(ack, sizeof(ack), "TA:%08lX:%s", (unsigned long)token, result);
  if (bleSession && bleSession->isReady())
    bleSession->characteristic()->notify(reinterpret_cast<const uint8_t*>(ack), length, bleSession->peer());
}


constexpr size_t RAW_CAPTURE_SIZE=128;
struct RawWrite {
  uint64_t arrivalUs;
  uint16_t size;
  uint16_t captured;
  uint8_t data[RAW_CAPTURE_SIZE];
};

void put32(uint8_t* p,uint32_t n) { for(int i=0;i<4;++i) p[i]=n>>(8*i); }
bool sendAck(void*,uint32_t sequence,uint32_t size,BLETestReceiver::Status status) {
  uint8_t ack[10]={1,uint8_t(status)};
  put32(ack+2,sequence); put32(ack+6,size);
  auto* characteristic=bleSession ? bleSession->characteristic() : nullptr;
  return characteristic && bleSession->isReady() &&
    characteristic->notify(ack,sizeof(ack),bleSession->peer());
}
void queueReport(void*,const BLETestReceiver::Result& r) {
  if(xQueueSend(reports,&r,0)!=pdTRUE) ++droppedLogs;
}
BLETestReceiver receiver(sendAck,queueReport,nullptr);

class IntegrationObserver final: public BleSessionObserver {
public:
  void onBleSessionTimeout() override {
    xSemaphoreTake(receiverMutex,portMAX_DELAY);
    if (refreshFlow.requested()) {
      DiagnosticStore::shared().count(DiagnosticCounter::DataTimeout);
      DiagnosticStore::shared().event(EventCode::DATA_REQUEST_TIMEOUT,LogLevel::Warn,0,0,latestRequest);
    }
    xSemaphoreGive(receiverMutex);
  }
  void onBleWrite(NimBLECharacteristic* c,NimBLEConnInfo& info) override {
    const uint64_t arrival=esp_timer_get_time();
    const auto value=c->getValue();
    const bool deliveryHeader=PayloadDelivery::isHeader(value.data(),value.size());
    if(rawLogging && !deliveryHeader && wireMode!=3) {
      RawWrite raw{};
      raw.arrivalUs=arrival;
      raw.size=value.size();
      raw.captured=value.size()<RAW_CAPTURE_SIZE ? value.size() : RAW_CAPTURE_SIZE;
      memcpy(raw.data,value.data(),raw.captured);
      if(xQueueSend(rawWrites,&raw,0)!=pdTRUE) ++droppedRawLogs;
    }
    xSemaphoreTake(receiverMutex,portMAX_DELAY);
    if(bleSession && info.getConnHandle()==bleSession->peer()) {
      // Route configuration separately, even during screen-off standby. Never
      // append it to a transit payload or change the connection's wire mode.
      // Six 20-byte UT:<token>:<0..5>:RRGGBB packets, then UT:<token>:C.
      // Nothing is persisted or displayed until the entire transaction commits.
      if (wireMode != 1 && value.size() >= 3 && memcmp(value.data(), "UT:", 3) == 0) {
        uint32_t token = 0, rgb = 0;
        const bool tokenValid = value.size() >= 13 && value[11] == ':' && parseHex(value.data()+3, 8, token);
        if (themeMask && uint32_t(millis()-themeStartedMs) >= 10000) themeMask = 0;
        const bool field = tokenValid && value.size() == 20 && value[12] >= '0' && value[12] <= '5' &&
          value[13] == ':' && parseHex(value.data()+14, 6, rgb);
        if (field && value[12] == '0') { themeToken = token; themeMask = 0; themeStartedMs = millis(); }
        if (field && token == themeToken && (themeMask || value[12] == '0')) {
          const uint8_t index = value[12]-'0';
          incomingTheme.rgb[index] = rgb;
          themeMask |= uint8_t(1 << index);
        } else if (tokenValid && value.size() == 13 && value[12] == 'C' && token == themeToken && themeMask == 0x3F) {
          UiColorRequest request{};
          request.token = token; request.session = connectionSession;
          request.valid = true; request.isTheme = true; request.theme = incomingTheme;
          if (xQueueSend(colorRequests, &request, 0) != pdTRUE) themeAck(token, "E3");
          themeMask = 0;
        } else {
          themeMask = 0;
          themeAck(tokenValid ? token : 0, "E1");
        }
        xSemaphoreGive(receiverMutex);
        return;
      }
      if (wireMode != 1 && value.size() >= 3 && memcmp(value.data(), "UC:", 3) == 0) {
        UiColorRequest request{};
        request.session = connectionSession;
        const bool hasToken = value.size() >= 12 && value[11] == ':' &&
          parseHex(value.data()+3, 8, request.token);
        if (!hasToken) request.token = 0;
        request.valid = hasToken && value.size() == 19 && value[12] == '#' &&
          parseHex(value.data()+13, 6, request.rgb);
        if (xQueueSend(colorRequests, &request, 0) != pdTRUE) colorAck(request.token, "E3");
        xSemaphoreGive(receiverMutex);
        return;
      }
      if(deliveryHeader) {
        const uint64_t tx=value.size()>=11 ? PayloadDelivery::transaction(value.data()) : 0;
        if(deliveryFrame.active || deliveryFrame.ready) receiveFailure(deliveryFrame.tx,PayloadDelivery::Frame::Interrupted);
        wireMode=3;
        if(uint32_t(tx>>32)!=transactionBoot || uint32_t(tx)<connectionFirstRequest || uint32_t(tx)>requestSequence || tx==lastApplied || refreshFlow.paused()) {
          receiveFailure(tx,refreshFlow.paused() ? PayloadDelivery::Frame::Paused : PayloadDelivery::Frame::StaleTransaction);
          deliveryFrame.reset();
        } else if(!deliveryFrame.begin(value.data(),value.size(),arrival)) {
          receiveFailure(tx,deliveryFrame.error);
        }
        deliveryFrame.lastActivity=arrival;
        xSemaphoreGive(receiverMutex); return;
      }
      if(wireMode==3) {
        if(deliveryFrame.active) {
          deliveryFrame.lastActivity=arrival;
          if(!deliveryFrame.chunks) {
            deliveryFrame.started=arrival;
            DiagnosticStore::shared().event(EventCode::RESPONSE_RX_STARTED,LogLevel::Info,deliveryFrame.expectedBytes,deliveryFrame.expectedChunks,deliveryFrame.tx);
          }
          const uint64_t tx=deliveryFrame.tx;
          const bool accepted=deliveryFrame.accept(value.data(),value.size());
          // value1 packs chunk/total (16 bits each); value2 is this body chunk's bytes.
          DiagnosticStore::shared().event(EventCode::RESPONSE_RX_CHUNK,accepted ? LogLevel::Info : LogLevel::Warn,
            int32_t(uint32_t(deliveryFrame.chunks)<<16 | deliveryFrame.expectedChunks),value.size(),tx);
          if(!accepted) receiveFailure(tx,deliveryFrame.error);
          else if(deliveryFrame.ready)
            DiagnosticStore::shared().event(EventCode::RESPONSE_RX_COMPLETE,LogLevel::Info,deliveryFrame.bytes,deliveryFrame.chunks,tx);
        } else if(deliveryFrame.tx) receiveFailure(deliveryFrame.tx,PayloadDelivery::Frame::LengthMismatch);
        xSemaphoreGive(receiverMutex); return;
      }
      if(refreshFlow.requested() && value.size()!=0 && !sawRefreshBytes) {
        sawRefreshBytes=true; e2eReceiving=true;
        DiagnosticStore::shared().event(EventCode::DATA_RESPONSE_STARTED);
        DiagnosticStore::shared().event(EventCode::PAYLOAD_RX_START);
      }
      if(wireMode==0 && value.size()!=0) wireMode=uint8_t(value[0])==0xc0 ? 1 : 2;
      if(wireMode==1) receiver.accept(reinterpret_cast<const uint8_t*>(value.data()),value.size(),arrival);
      else if(value.size()!=0 && !refreshFlow.paused()) {
        transitText.accept(value.data(),value.size(),arrival);
      }
    }
    xSemaphoreGive(receiverMutex);
  }
  void onBleSubscribe(NimBLECharacteristic*,NimBLEConnInfo&,uint16_t) override {
  }
  bool onBleConnected(NimBLEServer*,NimBLEConnInfo& info) override {
    xSemaphoreTake(receiverMutex,portMAX_DELAY);
    // A peripheral does not see the central's scans/failed over-air attempts.
    // Count only concrete incoming connections presented by NimBLE.
    MetricsStore::shared().recordBleAttempt();
    MetricsStore::shared().recordBleSuccess();
    wireMode=0; transitText.reset(); deliveryFrame.reset();
    themeMask = 0;
    ++connectionSession;
    connectionFirstRequest=requestSequence+1;
    refreshFlow.onConnected();
    e2eConnected=true;
    xSemaphoreGive(receiverMutex);
    return true;
  }
  void onBleDisconnected(NimBLEConnInfo&,int) override {
    xSemaphoreTake(receiverMutex,portMAX_DELAY);
    themeMask = 0;
    ++connectionSession;
    xQueueReset(colorRequests);
    failFetchEpisode();
    fetchEpisode=false;
    if(deliveryFrame.active || deliveryFrame.ready) receiveFailure(deliveryFrame.tx,PayloadDelivery::Frame::Interrupted);
    if(latestRequest && refreshFlow.requested()) DiagnosticStore::shared().event(EventCode::DATA_REQUEST_TIMEOUT,LogLevel::Warn,0,0,latestRequest);
    wireMode=0; transitText.reset(); deliveryFrame.reset();
    refreshFlow.onDisconnected();
    e2eDisconnected=true;
    receiver.disconnect();
    xSemaphoreGive(receiverMutex);
  }
};
static IntegrationObserver integrationObserver;
static BleSession session(DEVICE_NAME,SERVICE_UUID,CHARACTERISTIC_UUID,integrationObserver);
void printStats(const BLETestReceiver::Stats& s,uint64_t dropped) {
  // Freeze the measured receive interval; never include the summary's idle wait.
  double seconds=s.active && s.lastMessageUs>=s.startUs ? (s.lastMessageUs-s.startUs)/1e6 : 0;
  InfoLog.println("\n---------- BLE TEST SUMMARY ----------");
  InfoLog.printf("Messages received: %llu\nValid: %llu\nInvalid: %llu\nChecksum failures: %llu\n",
    s.messages,s.valid,s.invalid,s.checksumFailures);
  InfoLog.printf("Missing sequence (gaps observed): %llu\nDuplicates: %llu\nOut of order: %llu\nToo old to classify duplicate: %llu\n",
    s.missing,s.duplicates,s.outOfOrder,s.stale);
  InfoLog.printf("Payload bytes: %llu\nValid payload bytes: %llu\nBLE chunks: %llu\nWire bytes: %llu\n",
    s.bytes,s.validBytes,s.chunks,s.wireBytes);
  InfoLog.printf("Duration: %.6f s\nRate: %.2f valid msg/s\nThroughput: %.2f KB/s\n",
    seconds,seconds>0?s.valid/seconds:0,seconds>0?s.validBytes/1000.0/seconds:0);
  InfoLog.printf("Minimum: %lu B\nLargest: %lu B\nChunks/message: %.2f\n",
    (unsigned long)s.minimum,(unsigned long)s.maximum,s.messages?double(s.messageChunks)/s.messages:0);
  InfoLog.printf("Assembly avg: %.3f ms\nAssembly min: %.3f ms\nAssembly max: %.3f ms\n",
    s.messages?s.assemblySum/1000.0/s.messages:0,s.assemblyMin/1000.0,s.assemblyMax/1000.0);
  InfoLog.printf("ACK enqueue failures: %llu\nDropped log lines: %llu\n--------------------------------------\n",s.ackFailures,dropped);
}
void setupBleIntegration(void (*onRefreshStarted)(), void (*onUiColorChanged)()) {
  uiColorChanged=onUiColorChanged;
  refreshStarted=onRefreshStarted;
  receiverMutex=xSemaphoreCreateMutex();
  colorRequests=xQueueCreate(4,sizeof(UiColorRequest));
  reports=xQueueCreate(32,sizeof(BLETestReceiver::Result));
  rawWrites=xQueueCreate(16,sizeof(RawWrite));
  if(!receiverMutex || !reports || !rawWrites || !colorRequests) { WarnLog.println("Test receiver allocation failed"); while(true) delay(1000); }
  bleSession=&session;
  transactionBoot=MetricsStore::shared().get().bootCount;
  DebugLog.println("BLE lifecycle ready: on-demand CTA Tracker sessions | 115200 baud");
}

void printRawWrite(const RawWrite& raw) {
  DebugLog.printf("BLE WRITE | %u B | HEX ",raw.size);
  for(uint16_t i=0;i<raw.captured;++i) DebugLog.printf("%02X",raw.data[i]);
  if(raw.captured<raw.size) DebugLog.printf("...(+%u B)",raw.size-raw.captured);
  DebugLog.print(" | ASCII ");
  for(uint16_t i=0;i<raw.captured;++i) {
    const uint8_t c=raw.data[i];
    DebugLog.write(c>=32 && c<=126 ? c : '.');
  }
  if(raw.captured<raw.size) DebugLog.print("...");
  DebugLog.println();
}

// The only NEED_DATA notification. Called with receiverMutex held.
static bool requestRefresh(uint32_t now,bool& sent) {
  if(wireMode==1 || !bleSession || deliveryFrame.active || deliveryFrame.ready || requestSequence==UINT32_MAX) return false;
  if(!refreshFlow.requestRefresh(now,bleSession->isConnected(),bleSession->isReady())) return false;
  if(!fetchEpisode) {
    fetchEpisode=true;
    MetricsStore::shared().recordFetchAttempt();
  }
  // Never reset a partially received transfer merely because a retry is due.
  latestRequest=(uint64_t(transactionBoot)<<32)|++requestSequence;
  DiagnosticStore::shared().retainTransaction(latestRequest);
  uint8_t request[11]; PayloadDelivery::envelope(request,1,latestRequest);
  DiagnosticStore::shared().event(EventCode::DATA_REQUEST_SENT,LogLevel::Info,0,0,latestRequest);
  auto* characteristic=bleSession->characteristic();
  sent=characteristic && characteristic->notify(request,sizeof(request),bleSession->peer());
  refreshFlow.sent(sent);
  if(!sent) {
    failFetchEpisode();
    DiagnosticStore::shared().event(EventCode::DATA_REQUEST_FAILED,LogLevel::Warn,0,0,latestRequest);
  }
  return true;
}

static void printMetrics() {
  const auto m=MetricsStore::shared().get();
  InfoLog.println("[METRICS] Current aggregate (RAM snapshot)");
  InfoLog.printf("version=%lu bootCount=%lu buttonPressCount=%lu\n",
    (unsigned long)m.version,(unsigned long)m.bootCount,(unsigned long)m.buttonPressCount);
  InfoLog.printf("bootDataSuccessCount=%lu bootDataFailureCount=%lu startupPending=%lu\n",
    (unsigned long)m.bootDataSuccessCount,(unsigned long)m.bootDataFailureCount,(unsigned long)m.startupPending);
  InfoLog.printf("latencyUnder2s=%lu latency2To4s=%lu latency4To8s=%lu latency8To15s=%lu latencyOver15s=%lu\n",
    (unsigned long)m.latencyUnder2s,(unsigned long)m.latency2To4s,(unsigned long)m.latency4To8s,
    (unsigned long)m.latency8To15s,(unsigned long)m.latencyOver15s);
  InfoLog.printf("bleConnectAttempts=%lu bleConnectSuccesses=%lu bleConnectFailures=%lu\n",
    (unsigned long)m.bleConnectAttempts,(unsigned long)m.bleConnectSuccesses,(unsigned long)m.bleConnectFailures);
  InfoLog.printf("fetchAttempts=%lu fetchSuccesses=%lu fetchFailures=%lu unexpectedResetCount=%lu\n",
    (unsigned long)m.fetchAttempts,(unsigned long)m.fetchSuccesses,(unsigned long)m.fetchFailures,
    (unsigned long)m.unexpectedResetCount);
}

void openBleManualWindow() {
  if (bleSession) bleSession->openManualWindow();
}

void pollBleIntegration() {
  UiColorRequest colorRequest;
  if (xQueueReceive(colorRequests, &colorRequest, 0) == pdTRUE) {
    xSemaphoreTake(receiverMutex, portMAX_DELAY);
    const bool current = colorRequest.session == connectionSession && bleSession && bleSession->isConnected();
    xSemaphoreGive(receiverMutex);
    if (current) {
      // No NVS or display work in a BLE callback or under the receiver mutex.
      const bool saved = colorRequest.valid && (colorRequest.isTheme ? pallete::storeTheme(colorRequest.theme) : pallete::storeUiColor(colorRequest.rgb));
      if (saved && uiColorChanged) uiColorChanged();
      char result[9];
      if (saved && colorRequest.isTheme) snprintf(result, sizeof(result), "%08lX", (unsigned long)pallete::fingerprint(pallete::theme()));
      else if (saved) snprintf(result, sizeof(result), "#%06lX", (unsigned long)pallete::uiColor());
      else strcpy(result, colorRequest.valid ? "E2" : "E1");
      xSemaphoreTake(receiverMutex, portMAX_DELAY);
      // Never acknowledge an old request to a new connection using the same handle.
      if (colorRequest.session == connectionSession) {
        if (colorRequest.isTheme) themeAck(colorRequest.token, result);
        else colorAck(colorRequest.token, result);
      }
      xSemaphoreGive(receiverMutex);
    }
  }

  const uint32_t loopNow=millis();
  if(bleSession) bleSession->update();
  const bool active=bleSession && bleSession->isActive();
  if(sessionWasActive && !active) nextSessionAttemptMs=loopNow+
    (bleSession && bleSession->permissive() ? 1000u : RefreshFlow::SLOW_RETRY_MS);
  sessionWasActive=active;
  bool shouldStart=false;
  xSemaphoreTake(receiverMutex,portMAX_DELAY);
  shouldStart=((bleSession && bleSession->permissive()) ||
    (!refreshFlow.paused() && refreshFlow.needsData(loopNow))) &&
    int32_t(loopNow-nextSessionAttemptMs)>=0;
  xSemaphoreGive(receiverMutex);
  if(shouldStart && bleSession && !active) {
    bleSession->beginSession();
    if(bleSession->permissive()) nextSessionAttemptMs=loopNow+1000u;
    sessionWasActive=true;
  }
  static char command[32]; static size_t length=0; static bool overflow=false;
  // Bound command work on each pass, including when a host floods Serial.
  for(int i=0;i<64 && Serial.available();++i) {
    char c=Serial.read();
    if(c=='\r' || c=='\n') {
      if(length || overflow) {
        command[length]=0;
        // UI tuning executes on the app loop, outside the BLE receiver mutex.
        if(!overflow && SerialLog::command(command)) { length=0; overflow=false; continue; }
        if(!overflow) InfoLog.printf("Serial > %s\n",command);
        if(!overflow && handleUiSerialCommand(command)) { length=0; overflow=false; continue; }
        bool show=false,showMetrics=false,resetMetrics=false,recognized=true;
        int permissiveCommand=-1;
        BLETestReceiver::Stats snapshot; uint64_t dropped; bool stopBle=false;
        xSemaphoreTake(receiverMutex,portMAX_DELAY);
        if(overflow) recognized=false;
        else if(!strcmp(command,"metrics")) showMetrics=true;
        else if(!strcmp(command,"metrics flush")) resetMetrics=true;
        else if(!strcmp(command,"stats")) show=true;
        else if(!strcmp(command,"receiver reset")) { receiver.reset(); xQueueReset(reports); xQueueReset(rawWrites); droppedLogs=0; droppedRawLogs=0; }
        else if(!strcmp(command,"verbose on")) receiver.setVerbose(true);
        else if(!strcmp(command,"verbose off")) { receiver.setVerbose(false); xQueueReset(reports); }
        else if(!strcmp(command,"raw on")) rawLogging=true;
        else if(!strcmp(command,"raw off")) { rawLogging=false; xQueueReset(rawWrites); }
        else if(!strcmp(command,"ble permissive on")) permissiveCommand=1;
        else if(!strcmp(command,"ble permissive off")) permissiveCommand=0;
        else if(!strcmp(command,"ble off")) {
          receiver.reset(); transitText.reset(); xQueueReset(reports); xQueueReset(rawWrites);
          stopBle=true;
        }
        else recognized=false;
        snapshot=receiver.stats(); dropped=droppedLogs;
        xSemaphoreGive(receiverMutex);
        if(permissiveCommand>=0 && bleSession) bleSession->setPermissive(permissiveCommand==1);
        if(stopBle && bleSession) bleSession->setPermissive(false);
        // Printing and NVS writes must stay outside the BLE receiver lock.
        if(showMetrics) printMetrics();
        else if(resetMetrics) {
          const bool saved=MetricsStore::shared().reset();
          InfoLog.println(saved ? "[METRICS] Counters cleared and saved to NVS" :
            "[METRICS] RAM cleared, but NVS save FAILED; old persisted metrics may remain");
        }
        else if(show) printStats(snapshot,dropped);
        else InfoLog.println(recognized?"OK":"ERR unknown command\ntype \"help\"");
      }
      length=0; overflow=false;
    } else if(length<sizeof(command)-1) command[length++]=c;
    else overflow=true;
  }
  xSemaphoreTake(receiverMutex,portMAX_DELAY);
  const bool connectedEvent=e2eConnected, disconnectedEvent=e2eDisconnected, receivingEvent=e2eReceiving;
  e2eConnected=e2eDisconnected=e2eReceiving=false;
  bool requestAttempted=false, requestSent=false;
  if(deliveryFrame.active && uint64_t(esp_timer_get_time())-deliveryFrame.lastActivity>=5000000) {
    receiveFailure(deliveryFrame.tx,PayloadDelivery::Frame::Interrupted);
    DiagnosticStore::shared().event(EventCode::DATA_REQUEST_TIMEOUT,LogLevel::Warn,0,0,deliveryFrame.tx);
    deliveryFrame.reset(); // Existing request scheduling can resume; no payload retransmission is added.
  }
  requestAttempted=requestRefresh(millis(),requestSent);
  const uint32_t attempt=refreshFlow.attemptCount();
  const bool hasData=refreshFlow.hasTransitData();
  const uint32_t age=uint32_t(millis()-refreshFlow.lastDataReceivedMs())/1000;
  receiver.poll(esp_timer_get_time());
  bool summary=receiver.takeSummary();
  auto snapshot=receiver.stats(); uint64_t dropped=droppedLogs;
  xSemaphoreGive(receiverMutex);
  if(connectedEvent) DebugLog.println("[E2E] BLE connected");
  if(disconnectedEvent) DebugLog.println("[DATA] BLE disconnected; NEED_DATA retries suspended");
  if(connectedEvent || requestAttempted) {
    if(hasData) DebugLog.printf("[DATA] data age=%lus\n",static_cast<unsigned long>(age));
    else DebugLog.println("[DATA] data age=none");
  }
  if(requestAttempted && refreshStarted) refreshStarted();
  if(requestAttempted) {
    DebugLog.printf("[DATA] NEED_DATA attempt=%lu %s\n",static_cast<unsigned long>(attempt),requestSent ? "sent" : "enqueue failed; will retry");
    if(requestSent) {
      DebugLog.println("[BLE] requesting fresh data");
    }
  }
  if(receivingEvent) DebugLog.println("[E2E] receiving payload");
  if(summary) printStats(snapshot,dropped);
  RawWrite raw;
  if(xQueueReceive(rawWrites,&raw,0)==pdTRUE) printRawWrite(raw);
  BLETestReceiver::Result r;
  // Serial never holds the receiver mutex, and the callback never waits for this queue.
  if(xQueueReceive(reports,&r,0)==pdTRUE) {
    DebugLog.printf("RX #%lu | %lu B | %lu chunks | %.3f ms | %s",
      (unsigned long)r.sequence,(unsigned long)r.size,(unsigned long)r.chunks,
      r.assemblyUs/1000.0,r.status==BLETestReceiver::OK?"CRC OK":BLETestReceiver::statusName(r.status));
    if(r.status==BLETestReceiver::SIZE_ERROR) DebugLog.printf(" | expected %lu | got %lu",(unsigned long)r.declared,(unsigned long)r.size);
    if(r.status==BLETestReceiver::MALFORMED) {
      DebugLog.printf(" | decoded %lu B | version %u | type %u",(unsigned long)r.decodedBytes,r.version,r.type);
      if(r.shortFrame) DebugLog.print(" | frame shorter than 14 B");
      if(r.badEscape) DebugLog.print(" | invalid/incomplete SLIP escape");
      if(r.truncated) DebugLog.print(" | frame timeout/disconnect");
      if(!r.shortFrame && r.version!=1) DebugLog.print(" | expected version 1");
      if(!r.shortFrame && r.type!=1 && r.type!=2) DebugLog.print(" | expected type 1 or 2");
      if(!r.shortFrame && r.type==2 && r.size!=0) DebugLog.print(" | END_TEST payload must be empty");
    }
    if(r.missing) DebugLog.printf(" | WARNING missing %llu before #%lu",r.missing,(unsigned long)r.sequence);
    if(r.duplicate) DebugLog.print(" | DUPLICATE");
    if(r.outOfOrder) DebugLog.print(" | OUT OF ORDER");
    if(r.stale) DebugLog.print(" | OUTSIDE SEQUENCE WINDOW");
    DebugLog.println();
  }
  delay(1);
}

bool bleWakeTestEnabled() { return false; }
bool bleSessionIsActive() { return bleSession && bleSession->isActive(); }
bool bleIsReady() {
  return bleSession && bleSession->isReady();
}
bool bleIsConnected() {
  return bleSession && bleSession->isConnected();
}
bool takeTransitPayload(String& payload, uint64_t& transactionId) {
  transactionId=0;
  xSemaphoreTake(receiverMutex,portMAX_DELAY);
  if(wireMode==3) {
    const bool ready=deliveryFrame.ready;
    if(ready) {
      transactionId=deliveryFrame.tx;
      payload=String(reinterpret_cast<const char*>(deliveryFrame.data),deliveryFrame.bytes);
      deliveryFrame.reset();
    }
    xSemaphoreGive(receiverMutex);
    return ready;
  }
  xSemaphoreGive(receiverMutex);
  bool ready=false, overflow=false;
  xSemaphoreTake(receiverMutex,portMAX_DELAY);
  // Legacy iOS text has no length/delimiter: collect a single send until 250 ms idle.
  if(transitText.ready(esp_timer_get_time())) {
    overflow=transitText.invalid();
    if(overflow) {
      refreshFlow.finish(false,millis());
      failFetchEpisode();
    }
    if(!overflow) {
      payload=String(transitText.text());
      ready=true;
    }
    transitText.reset();
  }
  xSemaphoreGive(receiverMutex);
  if(overflow) WarnLog.println("Transit payload rejected: exceeds 2048 bytes or contains NUL");
  if(overflow) {
    DiagnosticStore::shared().count(DiagnosticCounter::InvalidPayload);
    DiagnosticStore::shared().event(EventCode::PAYLOAD_PARSE_FAILURE,LogLevel::Warn);
  }
  if(overflow && bleSession) bleSession->abortSession("transfer failed");
  if(ready) DebugLog.println("[BLE] payload complete");
  if(ready) {
    DiagnosticStore::shared().event(EventCode::PAYLOAD_RX_COMPLETE,LogLevel::Info,payload.length());
    DiagnosticStore::shared().event(EventCode::DATA_RESPONSE_COMPLETE);
  }
  return ready;
}

bool transitRefreshPending() {
  xSemaphoreTake(receiverMutex,portMAX_DELAY);
  bool pending=refreshFlow.requested();
  xSemaphoreGive(receiverMutex);
  return pending;
}
void setTransitRefreshPaused(bool paused) {
  xSemaphoreTake(receiverMutex,portMAX_DELAY);
  const bool changed=refreshFlow.paused()!=paused;
  if(changed) {
    if(paused) { failFetchEpisode(); fetchEpisode=false; }
    refreshFlow.setPaused(paused);
    // Ignore a late/incomplete pre-standby response; wake will request a new board.
    transitText.reset();
    if(deliveryFrame.active || deliveryFrame.ready) receiveFailure(deliveryFrame.tx,PayloadDelivery::Frame::Paused);
    deliveryFrame.reset();
    sawRefreshBytes=false;
    e2eReceiving=false;
  }
  xSemaphoreGive(receiverMutex);
  if(paused && changed && bleSession) bleSession->abortSession("session suspended for standby");
  if(!paused && changed) nextSessionAttemptMs=0;
  if(changed) DebugLog.println(paused ? "[DATA] Standby: NEED_DATA paused; RAM board retained" : "[DATA] Wake: needsData=true; NEED_DATA resumes");
}
void finishTransitRefresh(bool success) {
  xSemaphoreTake(receiverMutex,portMAX_DELAY);
  if(success) {
    // Unsolicited valid app pushes are not device fetch attempts.
    if(fetchEpisode) MetricsStore::shared().recordFetchSuccess();
    fetchEpisode=false;
  } else failFetchEpisode();
  refreshFlow.finish(success,millis());
  if(success) sawRefreshBytes=false;
  xSemaphoreGive(receiverMutex);
  if(success) {
    DebugLog.println("[DATA] Complete valid train payload received; data age reset to 0");
    DebugLog.println("[DATA] NEED_DATA retries stopped");
    DebugLog.println("[BLE] payload committed");
    if(bleSession) bleSession->markTransactionComplete();
  } else if(bleSession) {
    bleSession->abortSession("transfer failed");
  }
}
bool takeTransitRefreshFailure() {
  xSemaphoreTake(receiverMutex,portMAX_DELAY);
  bool failed=refreshFlow.takeFailure();
  xSemaphoreGive(receiverMutex);
  return failed;
}

static void sendApplicationAck(uint64_t tx,uint8_t status,uint16_t bytes) {
  if(!tx) return;
  uint8_t packet[14]; PayloadDelivery::envelope(packet,3,tx); packet[11]=status; PayloadDelivery::put16(packet+12,bytes);
  const bool sent=bleSession && bleSession->sendDiagnosticNotification(packet,sizeof(packet));
  DiagnosticStore::shared().event(sent ? EventCode::DATA_APPLIED_ACK_QUEUED : EventCode::DATA_APPLIED_ACK_FAILED,
    sent ? LogLevel::Info : LogLevel::Warn,bytes,status,tx);
  DebugLog.printf("[DATA] ACK transaction=%lu-%lu status=%u bytes=%u queued=%u\n",
    (unsigned long)(tx>>32),(unsigned long)tx,status,bytes,sent);
}
void acknowledgeTransitApplied(uint64_t tx,uint16_t bytes) {
  xSemaphoreTake(receiverMutex,portMAX_DELAY); lastApplied=tx; xSemaphoreGive(receiverMutex);
  sendApplicationAck(tx,0,bytes);
}
void rejectTransitPayload(uint64_t tx,uint8_t error,uint16_t bytes) { sendApplicationAck(tx,error,bytes); }

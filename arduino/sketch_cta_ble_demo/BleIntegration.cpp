#include <Arduino.h>
#include <NimBLEDevice.h>
#include <esp_timer.h>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>
#include <freertos/queue.h>
#include "BLETestReceiver.h"
#include "BleWakeTest.h"
BleWakeTest wakeTest;
#include "BleIntegration.h"
#include "RefreshFlow.h"
static RefreshFlow refreshFlow;
static void (*refreshStarted)()=nullptr;
static bool e2eConnected=false, e2eReceiving=false;
static bool sawRefreshBytes=false;


static uint8_t wireMode=0; // 0 unknown, 1 SLIP test, 2 legacy transit text
#include "TransitTextBuffer.h"
static TransitTextBuffer transitText;


const char* DEVICE_NAME = "CTA Tracker";
const char* SERVICE_UUID = "7A1C0001-8F4A-4D2B-9A57-1C2D3E4F5001";
const char* CHARACTERISTIC_UUID = "7A1C0002-8F4A-4D2B-9A57-1C2D3E4F5001";
NimBLECharacteristic* characteristic;
SemaphoreHandle_t receiverMutex;
QueueHandle_t reports;
QueueHandle_t rawWrites;
uint16_t peer=BLE_HS_CONN_HANDLE_NONE;
bool subscribed=false;
uint64_t droppedLogs=0;
uint64_t droppedRawLogs=0;
volatile bool rawLogging=true;

static void beginButtonRefresh() {
  Serial.println("[E2E] button pressed");
  xSemaphoreTake(receiverMutex,portMAX_DELAY);
  sawRefreshBytes=false;
  transitText.reset();
  xSemaphoreGive(receiverMutex);
  if(refreshStarted) refreshStarted();
  Serial.println("[E2E] advertising");
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
  return subscribed && peer!=BLE_HS_CONN_HANDLE_NONE && characteristic->notify(ack,sizeof(ack),peer);
}
void queueReport(void*,const BLETestReceiver::Result& r) {
  if(xQueueSend(reports,&r,0)!=pdTRUE) ++droppedLogs;
}
BLETestReceiver receiver(sendAck,queueReport,nullptr);

class TestCallbacks: public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* c,NimBLEConnInfo& info) override {
    if(wakeTest.enabled()) return;
    const uint64_t arrival=esp_timer_get_time();
    const auto value=c->getValue();
    if(rawLogging) {
      RawWrite raw{};
      raw.arrivalUs=arrival;
      raw.size=value.size();
      raw.captured=value.size()<RAW_CAPTURE_SIZE ? value.size() : RAW_CAPTURE_SIZE;
      memcpy(raw.data,value.data(),raw.captured);
      if(xQueueSend(rawWrites,&raw,0)!=pdTRUE) ++droppedRawLogs;
    }
    xSemaphoreTake(receiverMutex,portMAX_DELAY);
    if(info.getConnHandle()==peer && !wakeTest.enabled()) {
      if(refreshFlow.requested() && value.size()!=0 && !sawRefreshBytes) {
        sawRefreshBytes=true; e2eReceiving=true;
      }
      if(wireMode==0 && value.size()!=0) wireMode=uint8_t(value[0])==0xc0 ? 1 : 2;
      if(wireMode==1) receiver.accept(reinterpret_cast<const uint8_t*>(value.data()),value.size(),arrival);
      else if(value.size()!=0) {
        transitText.accept(value.data(),value.size(),arrival);
      }
    }
    xSemaphoreGive(receiverMutex);
  }
  void onSubscribe(NimBLECharacteristic*,NimBLEConnInfo& info,uint16_t value) override {
    xSemaphoreTake(receiverMutex,portMAX_DELAY);
    if(info.getConnHandle()==peer) subscribed=(value&1)!=0;
    xSemaphoreGive(receiverMutex);
  }
};
class ServerCallbacks: public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* server,NimBLEConnInfo& info) override {
    xSemaphoreTake(receiverMutex,portMAX_DELAY);
    if(peer==BLE_HS_CONN_HANDLE_NONE && wakeTest.onConnected(info.getConnHandle())) {
      peer=info.getConnHandle(); subscribed=false; wireMode=0; transitText.reset();
      refreshFlow.onConnected();
      e2eConnected=true;
    }
    else server->disconnect(info.getConnHandle());
    xSemaphoreGive(receiverMutex);
  }
  void onDisconnect(NimBLEServer*,NimBLEConnInfo& info,int) override {
    xSemaphoreTake(receiverMutex,portMAX_DELAY);
    if(info.getConnHandle()==peer) {
      subscribed=false; peer=BLE_HS_CONN_HANDLE_NONE; wireMode=0; transitText.reset();
      refreshFlow.onDisconnected();
      if(wakeTest.enabled()) receiver.reset(); else receiver.disconnect();
    }
    xSemaphoreGive(receiverMutex);
    wakeTest.onDisconnected(info.getConnHandle());
  }
};
void setupBle() {
  NimBLEDevice::init(DEVICE_NAME);
  NimBLEDevice::setMTU(128);
  auto* server=NimBLEDevice::createServer();
  wakeTest.begin(server,beginButtonRefresh);
  server->setCallbacks(new ServerCallbacks());
  auto* service=server->createService(SERVICE_UUID);
  characteristic=service->createCharacteristic(CHARACTERISTIC_UUID,
    NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR | NIMBLE_PROPERTY::NOTIFY);
  characteristic->setCallbacks(new TestCallbacks());
  service->start();
  auto* advertising=NimBLEDevice::getAdvertising();
  advertising->addServiceUUID(SERVICE_UUID);
  advertising->enableScanResponse(true);
  advertising->setName(DEVICE_NAME);
  advertising->start();
}
void printStats(const BLETestReceiver::Stats& s,uint64_t dropped) {
  // Freeze the measured receive interval; never include the summary's idle wait.
  double seconds=s.active && s.lastMessageUs>=s.startUs ? (s.lastMessageUs-s.startUs)/1e6 : 0;
  Serial.println("\n---------- BLE TEST SUMMARY ----------");
  Serial.printf("Messages received: %llu\nValid: %llu\nInvalid: %llu\nChecksum failures: %llu\n",
    s.messages,s.valid,s.invalid,s.checksumFailures);
  Serial.printf("Missing sequence (gaps observed): %llu\nDuplicates: %llu\nOut of order: %llu\nToo old to classify duplicate: %llu\n",
    s.missing,s.duplicates,s.outOfOrder,s.stale);
  Serial.printf("Payload bytes: %llu\nValid payload bytes: %llu\nBLE chunks: %llu\nWire bytes: %llu\n",
    s.bytes,s.validBytes,s.chunks,s.wireBytes);
  Serial.printf("Duration: %.6f s\nRate: %.2f valid msg/s\nThroughput: %.2f KB/s\n",
    seconds,seconds>0?s.valid/seconds:0,seconds>0?s.validBytes/1000.0/seconds:0);
  Serial.printf("Minimum: %lu B\nLargest: %lu B\nChunks/message: %.2f\n",
    (unsigned long)s.minimum,(unsigned long)s.maximum,s.messages?double(s.messageChunks)/s.messages:0);
  Serial.printf("Assembly avg: %.3f ms\nAssembly min: %.3f ms\nAssembly max: %.3f ms\n",
    s.messages?s.assemblySum/1000.0/s.messages:0,s.assemblyMin/1000.0,s.assemblyMax/1000.0);
  Serial.printf("ACK enqueue failures: %llu\nDropped log lines: %llu\n--------------------------------------\n",s.ackFailures,dropped);
}
void setupBleIntegration(void (*onRefreshStarted)()) {
  refreshStarted=onRefreshStarted;
  receiverMutex=xSemaphoreCreateMutex();
  reports=xQueueCreate(32,sizeof(BLETestReceiver::Result));
  rawWrites=xQueueCreate(16,sizeof(RawWrite));
  if(!receiverMutex || !reports || !rawWrites) { Serial.println("Test receiver allocation failed"); while(true) delay(1000); }
  setupBle();
  Serial.println("BLE test ready: CTA Tracker | 115200 baud | stats, reset, verbose on/off, raw on/off, ble off (wake: GPIO 9 button)");
}

void printRawWrite(const RawWrite& raw) {
  Serial.printf("BLE WRITE | %u B | HEX ",raw.size);
  for(uint16_t i=0;i<raw.captured;++i) Serial.printf("%02X",raw.data[i]);
  if(raw.captured<raw.size) Serial.printf("...(+%u B)",raw.size-raw.captured);
  Serial.print(" | ASCII ");
  for(uint16_t i=0;i<raw.captured;++i) {
    const uint8_t c=raw.data[i];
    Serial.write(c>=32 && c<=126 ? c : '.');
  }
  if(raw.captured<raw.size) Serial.print("...");
  Serial.println();
}

// The only REFRESH_REQUEST write. Called with receiverMutex held.
static bool requestRefresh(uint32_t now,bool& sent) {
  if(!refreshFlow.requestRefresh(now,peer!=BLE_HS_CONN_HANDLE_NONE,subscribed)) return false;
  sawRefreshBytes=false;
  static const uint8_t request[]="REFRESH_REQUEST";
  sent=characteristic->notify(request,sizeof(request)-1,peer);
  refreshFlow.sent(sent);
  return true;
}

void pollBleIntegration() {
  wakeTest.poll();
  static char command[32]; static size_t length=0; static bool overflow=false;
  // Bound command work on each pass, including when a host floods Serial.
  for(int i=0;i<64 && Serial.available();++i) {
    char c=Serial.read();
    if(c=='\r' || c=='\n') {
      if(length || overflow) {
        command[length]=0;
        bool show=false,recognized=true;
        BLETestReceiver::Stats snapshot; uint64_t dropped;
        xSemaphoreTake(receiverMutex,portMAX_DELAY);
        if(overflow) recognized=false;
        else if(!strcmp(command,"stats")) show=true;
        else if(!strcmp(command,"reset")) { receiver.reset(); xQueueReset(reports); xQueueReset(rawWrites); droppedLogs=0; droppedRawLogs=0; }
        else if(!strcmp(command,"verbose on")) receiver.setVerbose(true);
        else if(!strcmp(command,"verbose off")) { receiver.setVerbose(false); xQueueReset(reports); }
        else if(!strcmp(command,"raw on")) rawLogging=true;
        else if(!strcmp(command,"raw off")) { rawLogging=false; xQueueReset(rawWrites); }
        else if(!strcmp(command,"ble off")) {
          receiver.reset(); transitText.reset(); xQueueReset(reports); xQueueReset(rawWrites);
          wakeTest.enterBleOffState();
        }
        else recognized=false;
        snapshot=receiver.stats(); dropped=droppedLogs;
        xSemaphoreGive(receiverMutex);
        if(show) printStats(snapshot,dropped);
        else Serial.println(recognized?"OK":"Commands: stats, reset, verbose on/off, raw on/off, ble off");
      }
      length=0; overflow=false;
    } else if(length<sizeof(command)-1) command[length++]=c;
    else overflow=true;
  }
  xSemaphoreTake(receiverMutex,portMAX_DELAY);
  refreshFlow.poll(millis());
  const bool connectedEvent=e2eConnected, receivingEvent=e2eReceiving;
  e2eConnected=e2eReceiving=false;
  bool requestAttempted=false, requestSent=false;
  requestAttempted=requestRefresh(millis(),requestSent);
  receiver.poll(esp_timer_get_time());
  bool summary=receiver.takeSummary();
  auto snapshot=receiver.stats(); uint64_t dropped=droppedLogs;
  xSemaphoreGive(receiverMutex);
  if(connectedEvent) Serial.println("[E2E] BLE connected");
  if(requestAttempted && refreshStarted) refreshStarted();
  if(requestAttempted) Serial.println(requestSent ? "[REFRESH] request sent" : "[REFRESH] request enqueue failed");
  if(requestAttempted) Serial.println(requestSent ? "[E2E] REFRESH_REQUEST sent" : "[E2E] REFRESH_REQUEST enqueue failed");
  if(receivingEvent) Serial.println("[E2E] receiving payload");
  if(summary) printStats(snapshot,dropped);
  RawWrite raw;
  if(xQueueReceive(rawWrites,&raw,0)==pdTRUE) printRawWrite(raw);
  BLETestReceiver::Result r;
  // Serial never holds the receiver mutex, and the callback never waits for this queue.
  if(xQueueReceive(reports,&r,0)==pdTRUE) {
    Serial.printf("RX #%lu | %lu B | %lu chunks | %.3f ms | %s",
      (unsigned long)r.sequence,(unsigned long)r.size,(unsigned long)r.chunks,
      r.assemblyUs/1000.0,r.status==BLETestReceiver::OK?"CRC OK":BLETestReceiver::statusName(r.status));
    if(r.status==BLETestReceiver::SIZE_ERROR) Serial.printf(" | expected %lu | got %lu",(unsigned long)r.declared,(unsigned long)r.size);
    if(r.status==BLETestReceiver::MALFORMED) {
      Serial.printf(" | decoded %lu B | version %u | type %u",(unsigned long)r.decodedBytes,r.version,r.type);
      if(r.shortFrame) Serial.print(" | frame shorter than 14 B");
      if(r.badEscape) Serial.print(" | invalid/incomplete SLIP escape");
      if(r.truncated) Serial.print(" | frame timeout/disconnect");
      if(!r.shortFrame && r.version!=1) Serial.print(" | expected version 1");
      if(!r.shortFrame && r.type!=1 && r.type!=2) Serial.print(" | expected type 1 or 2");
      if(!r.shortFrame && r.type==2 && r.size!=0) Serial.print(" | END_TEST payload must be empty");
    }
    if(r.missing) Serial.printf(" | WARNING missing %llu before #%lu",r.missing,(unsigned long)r.sequence);
    if(r.duplicate) Serial.print(" | DUPLICATE");
    if(r.outOfOrder) Serial.print(" | OUT OF ORDER");
    if(r.stale) Serial.print(" | OUTSIDE SEQUENCE WINDOW");
    Serial.println();
  }
  delay(1);
}

bool bleWakeTestEnabled() { return wakeTest.enabled(); }
bool bleIsConnected() {
  xSemaphoreTake(receiverMutex,portMAX_DELAY);
  bool connected=peer!=BLE_HS_CONN_HANDLE_NONE;
  xSemaphoreGive(receiverMutex);
  return connected;
}
bool takeTransitPayload(String& payload) {
  bool ready=false, overflow=false;
  xSemaphoreTake(receiverMutex,portMAX_DELAY);
  // Legacy iOS text has no length/delimiter: collect a single send until 250 ms idle.
  if(transitText.ready(esp_timer_get_time())) {
    overflow=transitText.invalid();
    if(!overflow) {
      payload=String(transitText.text());
      ready=true;
    }
    transitText.reset();
  }
  xSemaphoreGive(receiverMutex);
  if(overflow) Serial.println("Transit payload rejected: exceeds 2048 bytes or contains NUL");
  return ready;
}

bool transitRefreshPending() {
  xSemaphoreTake(receiverMutex,portMAX_DELAY);
  bool pending=refreshFlow.requested();
  xSemaphoreGive(receiverMutex);
  return pending;
}
void finishTransitRefresh(bool success) {
  xSemaphoreTake(receiverMutex,portMAX_DELAY);
  refreshFlow.finish(success,millis());
  xSemaphoreGive(receiverMutex);
  if(success) {
    Serial.println("[REFRESH] payload received");
    Serial.println("[REFRESH] freshness timer reset");
  }
}
bool takeTransitRefreshFailure() {
  xSemaphoreTake(receiverMutex,portMAX_DELAY);
  bool failed=refreshFlow.takeFailure();
  xSemaphoreGive(receiverMutex);
  return failed;
}

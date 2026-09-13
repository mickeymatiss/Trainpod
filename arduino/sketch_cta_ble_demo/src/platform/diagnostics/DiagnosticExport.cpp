#include "DiagnosticExport.h"
#include "../ble/BleSession.h"
#include "../metrics/MetricsStore.h"
#include "../transport/BLETestReceiver.h"
#include <esp_system.h>
#include <esp_timer.h>
#include <esp_heap_caps.h>

namespace {
// Leave room for String allocator alignment and the terminating NUL.
constexpr size_t MAX_EXPORT_BYTES = 65000;
class CheckedJson {
public:
  explicit CheckedJson(String& value) : value_(value) {}
  CheckedJson& operator+=(const char* value) {
    const size_t count = strlen(value);
    if (good_ && (count > MAX_EXPORT_BYTES-value_.length() || !value_.concat(value,count))) good_ = false;
    return *this;
  }
  CheckedJson& operator+=(const String& value) { return *this += value.c_str(); }
  size_t length() const { return value_.length(); }
  void remove(size_t index) { if (good_) value_.remove(index); }
  bool good() const { return good_; }
  void reject() { good_ = false; }
private:
  String& value_;
  bool good_ = true;
};
void put32(uint8_t* p, uint32_t value) { for (int i=0;i<4;++i) p[i] = value >> (8*i); }
const char* levelName(LogLevel level) { return level == LogLevel::Debug ? "DEBUG" : level == LogLevel::Info ? "INFO" : level == LogLevel::Warn ? "WARN" : "ERROR"; }
void appendEntries(CheckedJson& text, const DiagnosticEntry* entries, size_t count) {
  char line[384];
  bool comma=false;
  text += "[";
  for (size_t i=0;i<count;++i) {
    const auto& e = entries[i];
    if(e.eventCode == EventCode::RESPONSE_RX_CHUNK) continue; // Compact, lossless rows below.
    if (comma) text += ",";
    comma=true;
    const int written = snprintf(line,sizeof(line),
      "{\"sequence\":%llu,\"uptimeMs\":%llu,\"unixTimeMs\":%lld,\"timestampSynced\":%s,\"sessionId\":\"%08lx\",\"level\":\"%s\",\"eventCode\":\"%s\",\"value1\":%ld,\"value2\":%ld}",
      (unsigned long long)e.sequence,(unsigned long long)e.uptimeMs,(long long)e.unixTimeMs,
      e.timestampSynced ? "true" : "false",(unsigned long)e.sessionId,levelName(e.level),
      DiagnosticStore::eventName(e.eventCode),(long)e.value1,(long)e.value2);
    if (written < 0 || size_t(written) >= sizeof(line)) { text.reject(); return; }
    text += line;
    if (e.transactionId) {
      text.remove(text.length()-1);
      snprintf(line,sizeof(line),",\"transactionId\":\"%lu-%lu\"}",
        (unsigned long)(e.transactionId>>32),(unsigned long)e.transactionId);
      text += line;
    }
    if (e.eventCode == EventCode::TIME_SYNC_RECEIVED || e.eventCode == EventCode::TIME_SYNC_UPDATED) {
      text.remove(text.length()-1);
      snprintf(line,sizeof(line),
        ",\"phoneUnixTimeMs\":%lld,\"deviceUptimeMsAtSync\":%llu,\"unixOffsetMs\":%lld}",
        (long long)(e.unixTimeMs-e.value1),
        (unsigned long long)(e.uptimeMs-e.value1),
        (long long)(e.unixTimeMs-int64_t(e.uptimeMs)));
      text += line;
    }
    if (e.eventCode == EventCode::STARTUP_TIMEOUT) {
      text.remove(text.length()-1);
      text += ",\"currentState\":\"";
      text += DiagnosticStore::eventName(EventCode(e.value1));
      text += "\"}";
    }
  }
  text += "]";
}
// Compact rows preserve every field without repeating JSON keys for each chunk/archive entry.
// Columns are exported explicitly; the phone expands them only for presentation.
void appendCompact(CheckedJson& text,const DiagnosticEntry* entries,size_t count,bool chunksOnly,bool& comma) {
  char line[384];
  for(size_t i=0;i<count;++i) {
    const auto& e=entries[i];
    if(chunksOnly && e.eventCode!=EventCode::RESPONSE_RX_CHUNK) continue;
    if(comma) text += ",";
    comma=true;
    const int n=snprintf(line,sizeof(line),
      "[%llu,%llu,%lld,%s,\"%08lx\",\"%s\",\"%s\",%ld,%ld,\"%lu-%lu\"]",
      (unsigned long long)e.sequence,(unsigned long long)e.uptimeMs,(long long)e.unixTimeMs,
      e.timestampSynced ? "true":"false",(unsigned long)e.sessionId,levelName(e.level),
      DiagnosticStore::eventName(e.eventCode),(long)e.value1,(long)e.value2,
      (unsigned long)(e.transactionId>>32),(unsigned long)e.transactionId);
    if(n<0 || size_t(n)>=sizeof(line)) { text.reject(); return; }
    text += line;
  }
}
}
DiagnosticExport& DiagnosticExport::shared() { static DiagnosticExport value; return value; }
bool DiagnosticExport::acceptCommand(const uint8_t* data, size_t size) {
  if (size < 5 || memcmp(data,"DIAG_",5)) return false;
  if (size == 11 && !memcmp(data,"DIAG_EXPORT",11)) {
    bool expected = false;
    if (busy_.compare_exchange_strong(expected,true)) {
      DiagnosticStore::shared().count(DiagnosticCounter::ExportAttempt);
      requested_ = true;
    } else duplicateRequest_ = true;
  } else if (size == 17 && !memcmp(data,"DIAG_ACK ",9)) {
    uint32_t id = 0;
    for (size_t i=9;i<17;++i) {
      const uint8_t c = data[i];
      int digit = c >= '0' && c <= '9' ? c-'0' : c >= 'a' && c <= 'f' ? c-'a'+10 : c >= 'A' && c <= 'F' ? c-'A'+10 : -1;
      if (digit < 0) return true;
      id = (id << 4) | digit;
    }
    ack_ = id;
  } else if (size == 11 && !memcmp(data,"DIAG_CANCEL",11)) cancel_ = true;
  return true; // Reserved commands must never enter the product parser.
}
bool DiagnosticExport::buildPayload() {
  if (!payload_.reserve(MAX_EXPORT_BYTES)) return false;
  payload_ = "";
  CheckedJson text(payload_);
  auto& store = DiagnosticStore::shared();
  store.snapshot(snapshot_);
  const auto c = store.counters();
  const auto m = MetricsStore::shared().get();
  char header[768];
  const uint64_t uptime = uint64_t(esp_timer_get_time())/1000;
  const int headerSize = snprintf(header,sizeof(header),
    "{\"schemaVersion\":1,\"metadata\":{\"firmwareBuild\":\"%s %s\",\"deviceModel\":\"%s\",\"bootId\":%lu,\"uptimeMs\":%llu,\"lastResetReason\":%lu,\"exportedAtUnixMs\":%lld,\"timestampSynced\":%s,\"sessionId\":\"%08lx\",\"phoneUnixTimeMs\":%lld,\"deviceUptimeMsAtSync\":%llu,\"unixOffsetMs\":%lld},\"metrics\":{",
    __DATE__,__TIME__,ESP.getChipModel(),(unsigned long)m.bootCount,(unsigned long long)uptime,
    (unsigned long)c.lastResetReason,snapshot_.timestampSynced ? int64_t(uptime)+snapshot_.unixOffsetMs : 0LL,
    snapshot_.timestampSynced ? "true" : "false",(unsigned long)snapshot_.sessionId,
    (long long)snapshot_.phoneUnixTimeMs,(unsigned long long)snapshot_.deviceUptimeMsAtSync,(long long)snapshot_.unixOffsetMs);
  if (headerSize < 0 || size_t(headerSize) >= sizeof(header)) return false;
  text += header;
#define FIELD(name) text += "\"" #name "\":" + String(m.name) + ","
  FIELD(version); FIELD(bootCount); FIELD(buttonPressCount); FIELD(bootDataSuccessCount); FIELD(bootDataFailureCount);
  FIELD(latencyUnder2s); FIELD(latency2To4s); FIELD(latency4To8s); FIELD(latency8To15s); FIELD(latencyOver15s);
  FIELD(bleConnectAttempts); FIELD(bleConnectSuccesses); FIELD(bleConnectFailures);
  FIELD(fetchAttempts); FIELD(fetchSuccesses); FIELD(fetchFailures); FIELD(unexpectedResetCount); FIELD(startupPending);
#undef FIELD
  text += "\"diagnosticExportsAttempted\":" + String(c.exportsAttempted) + ",";
  text += "\"diagnosticExportsSucceeded\":" + String(c.exportsSucceeded) + ",";
  text += "\"diagnosticExportsFailed\":" + String(c.exportsFailed) + ",";
  text += "\"bleTimeoutCount\":" + String(c.bleTimeouts) + ",";
  text += "\"bleDisconnectCount\":" + String(c.bleDisconnects) + ",";
  text += "\"dataRequestTimeoutCount\":" + String(c.dataTimeouts) + ",";
  text += "\"payloadParseFailureCount\":" + String(c.invalidPayloads) + ",";
  text += "\"startupTimeoutCount\":" + String(c.startupTimeouts) + ",";
  text += "\"advertisingSessionCount\":" + String(c.advertisingSessions) + ",";
  text += "\"timeSyncCount\":" + String(c.timeSyncs) + "},\"deviceErrors\":";
  appendEntries(text,snapshot_.errors,snapshot_.errorCount);
  text += ",\"deviceLogs\":";
  appendEntries(text,snapshot_.logs,snapshot_.logCount);
  text += ",\"compactDeviceColumns\":[\"sequence\",\"uptimeMs\",\"unixTimeMs\",\"timestampSynced\",\"sessionId\",\"level\",\"eventCode\",\"value1\",\"value2\",\"transactionId\"],\"deviceChunkLogs\":[";
  bool comma=false;
  appendCompact(text,snapshot_.logs,snapshot_.logCount,true,comma);
  // Include chunk errors that survived only in the dedicated error ring.
  for(size_t i=0;i<snapshot_.errorCount;++i) {
    bool inLogs=false;
    for(size_t j=0;j<snapshot_.logCount;++j) if(snapshot_.errors[i].sequence==snapshot_.logs[j].sequence) inLogs=true;
    if(!inLogs) appendCompact(text,&snapshot_.errors[i],1,true,comma);
  }
  text += "],\"deviceTransactionLogs\":[";
  comma=false;
  for(const auto& trace:snapshot_.transactions) appendCompact(text,trace.events,trace.count,false,comma);
  text += "]}";
  return text.good() && payload_.length() > 0 && payload_.length() <= MAX_EXPORT_BYTES;
}
bool DiagnosticExport::send(BleSession& session, uint8_t type, const uint8_t* data, size_t count) {
  uint8_t packet[128] = {0xd1,0xa6,1,type};
  if (count > sizeof(packet)-8) return false;
  put32(packet+4,id_);
  if (count) memcpy(packet+8,data,count);
  const bool sent = session.sendDiagnosticNotification(packet,count+8);
  if (!sent && !notificationFailureReported_) {
    notificationFailureReported_ = true;
    Serial.printf("[DIAG] Notification enqueue failed: kind=%u offset=%lu connected=%u; retrying\n",
      type,(unsigned long)offset_,session.isConnected());
  }
  return sent;
}
void DiagnosticExport::clear() {
  phase_ = Phase::Idle; payload_ = String(); busy_ = false; ack_ = 0;
}
void DiagnosticExport::fail(const char* reason, BleSession* session) {
  if (!busy_.load() || phase_ == Phase::Error) return;
  if (busy_.load()) {
    DiagnosticStore::shared().count(DiagnosticCounter::ExportFailure);
    const int code = !strcmp(reason,"disconnect_or_cancel") ? 1 : !strcmp(reason,"snapshot_allocation") ? 2 : !strcmp(reason,"export_timeout") ? 3 : !strcmp(reason,"mtu_too_small") ? 4 : 5;
    DiagnosticStore::shared().event(EventCode::DIAGNOSTIC_EXPORT_FAILED,LogLevel::Warn,code);
    errorCode_ = uint8_t(code);
  }
  Serial.printf("[DIAG] FAILED: %s id=%08lx phase=%u offset=%lu bytes=%u freeHeap=%lu largestBlock=%lu\n",
    reason,(unsigned long)id_,unsigned(phase_),(unsigned long)offset_,payload_.length(),
    (unsigned long)ESP.getFreeHeap(),(unsigned long)heap_caps_get_largest_free_block(MALLOC_CAP_8BIT));
  requested_ = false;
  if (session && session->isConnected()) {
    // Keep a bounded, non-blocking opportunity to deliver the terminal error.
    payload_ = String(); confirmed_ = millis(); lastSend_ = confirmed_-100;
    phase_ = Phase::Error;
  } else clear();
}
void DiagnosticExport::update(BleSession& session) {
  auto& store = DiagnosticStore::shared();
  if (duplicateRequest_.exchange(false))
    Serial.println("[DIAG] DIAG_EXPORT ignored: an export is already active");
  if (disconnected_.exchange(false) || cancel_.exchange(false)) {
    if (phase_ == Phase::Confirm || phase_ == Phase::Error) clear(); else fail("disconnect_or_cancel");
    return;
  }
  const uint32_t now = millis();
  if (requested_.exchange(false)) {
    store.event(EventCode::DIAGNOSTIC_EXPORT_REQUESTED);
    id_ = esp_random(); if (!id_ || id_ == lastAcknowledged_) ++id_;
    if (!id_) id_ = 1;
    started_ = now; offset_ = 0; lastSend_ = now-10;
    notificationFailureReported_ = false;
    Serial.printf("[DIAG] DIAG_EXPORT received: id=%08lx freeHeap=%lu largestBlock=%lu\n",
      (unsigned long)id_,(unsigned long)ESP.getFreeHeap(),
      (unsigned long)heap_caps_get_largest_free_block(MALLOC_CAP_8BIT));
    if (!store.flush()) { fail("counter_persistence",&session); return; }
    if (!buildPayload()) { fail("snapshot_allocation",&session); return; }
    checksum_ = BLETestReceiver::crc32(reinterpret_cast<const uint8_t*>(payload_.c_str()),payload_.length());
    Serial.printf("[DIAG] Snapshot ready: %u bytes, notification capacity=%u\n",payload_.length(),unsigned(session.notificationCapacity()));
    phase_ = Phase::Begin;
  }
  const uint32_t ack = ack_.exchange(0);
  if (ack && phase_ == Phase::AwaitAck && ack == id_ && session.isConnected()) {
    // An ACK proves the phone saved the validated file. Newer ring entries survive.
    store.count(DiagnosticCounter::ExportSuccess);
    store.purgeThrough(snapshot_.cutoff);
    store.event(EventCode::DIAGNOSTIC_EXPORT_COMPLETE);
    store.flush(); MetricsStore::shared().flush();
    Serial.printf("[DIAG] Receipt accepted: id=%08lx; exported logs cleared\n",(unsigned long)id_);
    lastAcknowledged_ = id_; confirmed_ = now; phase_ = Phase::Confirm;
  } else if (ack && ack == lastAcknowledged_ && !busy_.load()) {
    id_ = ack; send(session,4,nullptr,0); // Idempotent ACK retry, never purges twice.
  }
  if (!busy_.load()) return;
  if (phase_ == Phase::Error) {
    if (uint32_t(now-confirmed_) >= 1000) { clear(); return; }
    if (uint32_t(now-lastSend_) >= 100) {
      lastSend_ = now;
      send(session,5,&errorCode_,1);
    }
    return;
  }
  if (phase_ == Phase::Confirm && uint32_t(now-confirmed_) >= 1000) { clear(); return; }
  if (phase_ != Phase::Confirm && uint32_t(now-started_) >= 60000) { fail("export_timeout",&session); return; }
  if (!session.isConnected() || uint32_t(now-lastSend_) < 2) return;
  lastSend_ = now;
  uint8_t data[120]{};
  switch (phase_) {
    case Phase::Begin:
      data[0] = 1; data[1] = 0; put32(data+2,payload_.length()); put32(data+6,checksum_);
      if (send(session,1,data,10)) {
        Serial.println("[DIAG] BEGIN notification queued; streaming snapshot");
        phase_ = Phase::Data;
      }
      break;
    case Phase::Data: {
      const size_t maximum = session.notificationCapacity();
      if (maximum <= 12) { fail("mtu_too_small",&session); return; }
      const size_t count = std::min(size_t(payload_.length()-offset_),std::min(maximum-12,size_t(116)));
      put32(data,offset_); memcpy(data+4,payload_.c_str()+offset_,count);
      if (send(session,2,data,count+4)) { offset_ += count; if (offset_ == payload_.length()) phase_ = Phase::End; }
      break;
    }
    case Phase::End:
      put32(data,checksum_); if (send(session,3,data,4)) {
        Serial.println("[DIAG] END notification queued; waiting for saved receipt");
        phase_ = Phase::AwaitAck;
      }
      break;
    case Phase::Confirm: send(session,4,nullptr,0); break;
    default: break;
  }
}

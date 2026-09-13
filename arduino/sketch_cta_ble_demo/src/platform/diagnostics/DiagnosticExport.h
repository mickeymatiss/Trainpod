#pragma once
#include "DiagnosticStore.h"
#include <atomic>
class BleSession;

// Dedicated notification envelope, separate from product text and existing SLIP ACKs.
// D1 A6, version=1, type, exportId:u32 LE; BEGIN: schema:u16,total:u32,CRC32:u32;
// DATA: offset:u32,bytes; END: CRC32:u32; SAVED: empty. Commands fit a 20-byte ATT write.
class DiagnosticExport {
public:
  static DiagnosticExport& shared();
  bool acceptCommand(const uint8_t* data, size_t size);
  void disconnected() { disconnected_ = true; }
  void update(BleSession& session);
  bool busy() const { return busy_.load(); }
private:
  enum class Phase { Idle, Begin, Data, End, AwaitAck, Confirm, Error };
  std::atomic<bool> busy_{false}, requested_{false}, disconnected_{false}, cancel_{false};
  std::atomic<uint32_t> ack_{0};
  std::atomic<bool> duplicateRequest_{false};
  Phase phase_ = Phase::Idle;
  DiagnosticSnapshot snapshot_;
  String payload_;
  uint32_t id_ = 0, checksum_ = 0, offset_ = 0, started_ = 0, lastSend_ = 0, confirmed_ = 0;
  uint32_t lastAcknowledged_ = 0;
  uint8_t errorCode_ = 0;
  bool notificationFailureReported_ = false;
  bool buildPayload();
  bool send(BleSession& session, uint8_t type, const uint8_t* data, size_t count);
  void fail(const char* reason, BleSession* session = nullptr);
  void clear();
};

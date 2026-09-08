#pragma once
#include <stddef.h>
#include <stdint.h>

// Portable receive engine; caller serializes access. No allocation or Serial I/O.
class BLETestReceiver {
public:
  static constexpr size_t MAX_TEST_MESSAGE_SIZE = 32768;
  static constexpr uint64_t IDLE_US = 3000000;
  static constexpr uint64_t FRAME_TIMEOUT_US = 3000000;
  enum Status : uint8_t { OK, CHECKSUM_ERROR, MALFORMED, SIZE_ERROR };
  struct Result {
    uint32_t sequence, size, declared, chunks;
    uint64_t assemblyUs, missing;
    Status status;
    uint8_t version, type;
    uint32_t decodedBytes;
    bool truncated, badEscape, shortFrame;
    bool duplicate, outOfOrder, stale;
  };
  struct Stats {
    uint64_t messages=0, bytes=0, validBytes=0, valid=0, invalid=0;
    uint64_t checksumFailures=0, missing=0, duplicates=0, outOfOrder=0, stale=0;
    uint64_t chunks=0, wireBytes=0, messageChunks=0, ackFailures=0;
    uint64_t assemblySum=0, assemblyMin=0, assemblyMax=0;
    uint64_t startUs=0, firstMessageUs=0, lastMessageUs=0, lastTrafficUs=0;
    uint64_t lastInterMessageUs=0;
    uint32_t minimum=0, maximum=0;
    bool active=false;
  };
  using Ack = bool (*)(void*, uint32_t, uint32_t, Status);
  using Report = void (*)(void*, const Result&);
  BLETestReceiver(Ack ack, Report report, void* context): ack_(ack), report_(report), context_(context) {}
  void accept(const uint8_t* data, size_t size, uint64_t now);
  void poll(uint64_t now);
  void disconnect();
  void reset();
  Stats stats() const { return stats_; }
  bool takeSummary() { bool value=summary_; summary_=false; return value; }
  void setVerbose(bool value) { verbose_=value; }
  static uint32_t crc32(const uint8_t* data, size_t size);
  static const char* statusName(Status status);
private:
  static constexpr size_t WINDOW=4096;
  uint8_t buffer_[MAX_TEST_MESSAGE_SIZE+14] = {};
  uint32_t seen_[WINDOW/32] = {};
  Stats stats_;
  Ack ack_; Report report_; void* context_;
  size_t used_=0;
  uint64_t decoded_=0, first_=0, last_=0, writeId_=0, frameWrite_=0;
  uint32_t chunks_=0, highest_=0;
  bool framed_=false, escaped_=false, bad_=false, sequenceStarted_=false;
  bool haveMessage_=false;
  bool verbose_=true, summary_=false, idlePrinted_=false;
  void clearFrame();
  void finish(bool truncated=false);
  void track(Result& result);
};

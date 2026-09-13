#include "BLETestReceiver.h"
#include <string.h>
#include <algorithm>

namespace {
uint32_t le32(const uint8_t* p) {
  return uint32_t(p[0]) | uint32_t(p[1])<<8 | uint32_t(p[2])<<16 | uint32_t(p[3])<<24;
}
}
uint32_t BLETestReceiver::crc32(const uint8_t* data, size_t size) {
  uint32_t crc=0xffffffff;
  for(size_t i=0;i<size;++i) {
    crc ^= data[i];
    for(int bit=0;bit<8;++bit) crc=(crc>>1)^((0u-(crc&1))&0xedb88320);
  }
  return crc^0xffffffff;
}
const char* BLETestReceiver::statusName(Status s) {
  switch(s) { case OK:return "OK"; case CHECKSUM_ERROR:return "CHECKSUM_ERROR";
    case SIZE_ERROR:return "SIZE_ERROR"; default:return "MALFORMED"; }
}
void BLETestReceiver::clearFrame() {
  used_=0; decoded_=0; chunks_=0; first_=last_=frameWrite_=0;
  escaped_=bad_=false;
}
void BLETestReceiver::reset() {
  stats_=Stats{}; memset(seen_,0,sizeof(seen_)); sequenceStarted_=false;
  summary_=idlePrinted_=haveMessage_=false; framed_=false; clearFrame();
}
void BLETestReceiver::accept(const uint8_t* data, size_t size, uint64_t now) {
  if(!size) return;
  ++writeId_; ++stats_.chunks; stats_.wireBytes+=size;
  for(size_t i=0;i<size;++i) {
    uint8_t b=data[i];
    if(b==0xc0) {
      if(framed_ && (decoded_ || escaped_ || bad_)) {
        if(frameWrite_!=writeId_) { ++chunks_; frameWrite_=writeId_; }
        last_=now; finish();
      }
      clearFrame(); framed_=true;
      // Count a start delimiter even when it occupies its own BLE write.
      first_=last_=now; frameWrite_=writeId_; chunks_=1;
      continue;
    }
    if(!framed_) continue; // Ignore noise until an unambiguous delimiter.
    if(frameWrite_!=writeId_) { ++chunks_; frameWrite_=writeId_; }
    last_=now;
    if(escaped_) {
      escaped_=false;
      if(b==0xdc) b=0xc0;
      else if(b==0xdd) b=0xdb;
      else bad_=true;
    } else if(b==0xdb) { escaped_=true; continue; }
    ++decoded_;
    if(used_<sizeof(buffer_)) buffer_[used_++]=b;
    if(used_>=2 && buffer_[1]==1) {
      if(!stats_.active) { stats_.active=true; stats_.startUs=first_; }
      stats_.lastTrafficUs=now; idlePrinted_=false;
    }
  }
}
void BLETestReceiver::track(Result& r) {
  if(!sequenceStarted_) {
    sequenceStarted_=true; highest_=r.sequence;
    seen_[(r.sequence%WINDOW)/32] |= uint32_t(1)<<(r.sequence%32);
    return;
  }
  const uint32_t forward=r.sequence-highest_;
  if(forward && forward<0x80000000u) {
    r.missing=forward-1; stats_.missing+=r.missing;
    if(forward>=WINDOW) memset(seen_,0,sizeof(seen_));
    else for(uint32_t n=1;n<=forward;++n) {
      uint32_t id=highest_+n;
      seen_[(id%WINDOW)/32] &= ~(uint32_t(1)<<(id%32));
    }
    highest_=r.sequence;
  } else if(highest_-r.sequence>=WINDOW) {
    r.stale=true; r.outOfOrder=true; ++stats_.stale; ++stats_.outOfOrder;
    return;
  }
  uint32_t& word=seen_[(r.sequence%WINDOW)/32];
  uint32_t mask=uint32_t(1)<<(r.sequence%32);
  if(word&mask) { r.duplicate=true; ++stats_.duplicates; }
  else if(r.sequence!=highest_) { r.outOfOrder=true; ++stats_.outOfOrder; }
  word|=mask;
}
void BLETestReceiver::finish(bool truncated) {
  Result r{};
  r.version=used_>=1 ? buffer_[0] : 0;
  r.type=used_>=2 ? buffer_[1] : 0;
  r.decodedBytes=uint32_t(std::min<uint64_t>(decoded_,UINT32_MAX));
  r.truncated=truncated;
  r.badEscape=bad_ || escaped_;
  r.shortFrame=decoded_<14;
  r.sequence=used_>=6 ? le32(buffer_+2) : UINT32_MAX;
  r.declared=used_>=10 ? le32(buffer_+6) : 0;
  r.size=decoded_>=14 ? uint32_t(std::min<uint64_t>(decoded_-14,UINT32_MAX)) : 0;
  r.chunks=chunks_; r.assemblyUs=last_-first_;
  r.status=OK;
  if(r.truncated || r.badEscape || r.shortFrame || buffer_[0]!=1 ||
     (buffer_[1]!=1 && buffer_[1]!=2)) r.status=MALFORMED;
  else if(r.declared>MAX_TEST_MESSAGE_SIZE || decoded_>sizeof(buffer_) || r.size!=r.declared)
    r.status=SIZE_ERROR;
  else if(buffer_[1]==2 && r.size!=0) r.status=MALFORMED;
  else if(crc32(buffer_+10,r.size)!=le32(buffer_+10+r.size)) r.status=CHECKSUM_ERROR;

  // Notification is attempted before statistics or deferred logging.
  bool sent=ack_ && ack_(context_,r.sequence,r.size,r.status);
  if(!sent) ++stats_.ackFailures;
  if(used_>=2 && buffer_[1]==2 && r.status==OK) { summary_=true; idlePrinted_=true; return; }
  ++stats_.messages; stats_.bytes+=r.size; stats_.messageChunks+=r.chunks;
  if(r.status==OK) { ++stats_.valid; stats_.validBytes+=r.size; }
  else { ++stats_.invalid; if(r.status==CHECKSUM_ERROR) ++stats_.checksumFailures; }
  if(used_>=10 && buffer_[0]==1 && buffer_[1]==1) track(r);
  if(stats_.messages==1) { stats_.minimum=r.size; stats_.assemblyMin=r.assemblyUs; }
  stats_.minimum=std::min(stats_.minimum,r.size); stats_.maximum=std::max(stats_.maximum,r.size);
  stats_.assemblyMin=std::min(stats_.assemblyMin,r.assemblyUs);
  stats_.assemblyMax=std::max(stats_.assemblyMax,r.assemblyUs); stats_.assemblySum+=r.assemblyUs;
  if(used_>=2 && buffer_[1]==1) {
    if(!haveMessage_) { stats_.firstMessageUs=last_; haveMessage_=true; }
    else stats_.lastInterMessageUs=last_-stats_.lastMessageUs;
    stats_.lastMessageUs=last_; stats_.lastTrafficUs=last_;
  }
  if(verbose_ && report_) report_(context_,r);
}
void BLETestReceiver::poll(uint64_t now) {
  if(framed_ && (decoded_ || escaped_) && now-last_>=FRAME_TIMEOUT_US) {
    finish(true); clearFrame(); framed_=false;
  }
  if(stats_.active && !idlePrinted_ && now-stats_.lastTrafficUs>=IDLE_US) {
    summary_=true; idlePrinted_=true;
  }
}
void BLETestReceiver::disconnect() {
  // A partial message cannot carry over to another connection; no ACK can be delivered here.
  if(decoded_ || escaped_) { finish(true); }
  clearFrame(); framed_=false;
}

#pragma once
#include <stdint.h>
#include <stddef.h>
#include <string.h>

// P1/kind: request=1 (11 B), response header=2 (19 B), applied ACK=3 (14 B).
// Header: boot:u32, request:u32, bytes:u16, chunks:u16, CRC32:u32; all LE.
// Body chunks are the existing unmodified transit text.
namespace PayloadDelivery {
inline uint32_t u32(const uint8_t* p) { return uint32_t(p[0]) | uint32_t(p[1])<<8 | uint32_t(p[2])<<16 | uint32_t(p[3])<<24; }
inline uint16_t u16(const uint8_t* p) { return uint16_t(p[0]) | uint16_t(p[1])<<8; }
inline void put32(uint8_t* p,uint32_t n) { for(int i=0;i<4;++i) p[i]=n>>(8*i); }
inline void put16(uint8_t* p,uint16_t n) { p[0]=n; p[1]=n>>8; }
inline uint64_t transaction(const uint8_t* p) { return uint64_t(u32(p+3))<<32 | u32(p+7); }
inline void envelope(uint8_t* p,uint8_t kind,uint64_t tx) {
  p[0]='P'; p[1]='1'; p[2]=kind; put32(p+3,uint32_t(tx>>32)); put32(p+7,uint32_t(tx));
}
inline bool isHeader(const uint8_t* p,size_t n) { return n>=3 && p[0]=='P' && p[1]=='1' && p[2]==2; }
inline uint32_t crc32(const uint8_t* p,size_t n) {
  uint32_t crc=0xffffffff;
  for(size_t i=0;i<n;++i) { crc^=p[i]; for(int b=0;b<8;++b) crc=(crc>>1)^((crc&1)?0xedb88320:0); }
  return crc^0xffffffff;
}
class Frame {
public:
  enum Error : uint8_t { None=0, InvalidPayload=1, Unavailable=2, LengthMismatch=3, Checksum=4, StaleTransaction=5, Paused=6, Interrupted=7 };
  static constexpr size_t Capacity=2048;
  void reset() { tx=0; bytes=chunks=expectedBytes=expectedChunks=0; active=ready=false; error=None; }
  bool begin(const uint8_t* p,size_t n,uint64_t now) {
    reset();
    if(n!=19 || !isHeader(p,n)) { error=LengthMismatch; return false; }
    tx=transaction(p); expectedBytes=u16(p+11); expectedChunks=u16(p+13); checksum=u32(p+15); started=now;
    if(!tx || !expectedBytes || expectedBytes>Capacity || !expectedChunks || expectedChunks>expectedBytes) { error=LengthMismatch; return false; }
    active=true; return true;
  }
  bool accept(const uint8_t* p,size_t n) {
    if(!active || ready || error!=None) return false;
    ++chunks;
    if(!n || chunks>expectedChunks || n>expectedBytes-bytes) { error=LengthMismatch; active=false; return false; }
    memcpy(data+bytes,p,n); bytes+=n;
    if(chunks==expectedChunks || bytes==expectedBytes) {
      active=false;
      if(chunks!=expectedChunks || bytes!=expectedBytes) { error=LengthMismatch; return false; }
      if(crc32(data,bytes)!=checksum) { error=Checksum; return false; }
      ready=true; data[bytes]=0;
    }
    return true;
  }
  uint64_t tx=0, started=0, lastActivity=0;
  uint16_t bytes=0, chunks=0, expectedBytes=0, expectedChunks=0;
  uint32_t checksum=0;
  bool active=false, ready=false;
  Error error=None;
  uint8_t data[Capacity+1]{};
};
}

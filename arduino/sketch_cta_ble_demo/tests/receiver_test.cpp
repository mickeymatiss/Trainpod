#include "../src/platform/transport/BLETestReceiver.h"
#include <vector>
#include <cassert>
#include <cstdio>
using R=BLETestReceiver;
struct Ack { uint32_t seq,size; R::Status status; };
std::vector<Ack> acks;
std::vector<R::Result> logs;
R* active;
bool ack(void*,uint32_t seq,uint32_t size,R::Status status) {
  // ACK runs before the message's counters and report callback.
  acks.push_back({seq,size,status}); return true;
}
void report(void*,const R::Result& r) { assert(!acks.empty()); logs.push_back(r); }
void put(std::vector<uint8_t>& v,uint32_t n) { for(int i=0;i<4;++i) v.push_back(n>>(8*i)); }
std::vector<uint8_t> frame(uint32_t seq,size_t size,uint8_t type=1,int delta=0,bool corrupt=false) {
  std::vector<uint8_t> p(size); for(size_t i=0;i<size;++i) p[i]=i;
  std::vector<uint8_t> raw={1,type}; put(raw,seq); put(raw,size+delta);
  raw.insert(raw.end(),p.begin(),p.end()); put(raw,R::crc32(p.data(),p.size())^(corrupt?1:0));
  std::vector<uint8_t> wire={0xc0};
  for(auto b:raw) { if(b==0xc0) {wire.push_back(0xdb);wire.push_back(0xdc);} else if(b==0xdb) {wire.push_back(0xdb);wire.push_back(0xdd);} else wire.push_back(b); }
  wire.push_back(0xc0); return wire;
}
uint64_t now=100;
void send(R& r,const std::vector<uint8_t>& v,size_t chunk=125) {
  for(size_t i=0;i<v.size();i+=chunk) {r.accept(v.data()+i,std::min(chunk,v.size()-i),now); now+=1000;}
}
int main() {
  R r(ack,report,nullptr); active=&r;
  assert(R::crc32(reinterpret_cast<const uint8_t*>("123456789"),9)==0xcbf43926);
  for(uint32_t i=1;i<=100;++i) send(r,frame(i,512));
  auto s=r.stats();
  assert(s.messages==100 && s.valid==100 && s.validBytes==51200 && s.missing==0);
  assert(acks.size()==100 && s.chunks==500 && logs.back().chunks==5 && logs.back().assemblyUs==4000);
  auto last=s.lastMessageUs;
  send(r,frame(101,0,2)); assert(r.takeSummary()); assert(r.stats().messages==100);
  assert(r.stats().lastMessageUs==last);
  r.poll(now+R::IDLE_US); assert(!r.takeSummary());
  r.reset(); acks.clear(); logs.clear();
  send(r,frame(41,512));send(r,frame(42,512));send(r,frame(44,512));send(r,frame(43,512));send(r,frame(44,512));
  s=r.stats();assert(s.missing==1 && s.outOfOrder==1 && s.duplicates==1);
  send(r,frame(45,512,1,0,true)); assert(acks.back().status==R::CHECKSUM_ERROR);
  send(r,frame(46,504,1,8)); assert(acks.back().status==R::SIZE_ERROR && acks.back().size==504);
  send(r,frame(47,32768)); assert(acks.back().status==R::OK);
  send(r,frame(48,32769)); assert(acks.back().status==R::SIZE_ERROR);
  send(r,frame(49,512)); assert(acks.back().status==R::OK);
  auto v=frame(50,512);r.accept(v.data(),30,now);now+=R::FRAME_TIMEOUT_US;r.poll(now);
  assert(acks.back().status==R::MALFORMED);send(r,frame(51,512));assert(acks.back().status==R::OK);
  r.reset();send(r,frame(0xffffffff,10));send(r,frame(0,10));assert(r.stats().missing==0);
  r.reset();auto f=frame(1,256);send(r,f,1);assert(acks.back().status==R::OK && logs.back().chunks==f.size());
  r.reset();send(r,frame(1,0)); assert(acks.back().status==R::OK);
  r.poll(now+R::IDLE_US); assert(r.takeSummary());r.poll(now+R::IDLE_US+1);assert(!r.takeSummary());
  r.reset();send(r,frame(1,10));send(r,frame(5000,10));send(r,frame(1,10));assert(r.stats().stale==1);
  r.reset();r.setVerbose(false);size_t n=logs.size();send(r,frame(1,512));assert(logs.size()==n && acks.back().status==R::OK);
  r.reset();auto one=frame(1,10),two=frame(2,10);one.insert(one.end(),two.begin(),two.end());send(r,one,1000);assert(r.stats().valid==2 && r.stats().chunks==1);
  uint8_t malformed[]={0xc0,1,1,0xdb,0x11,0xc0};send(r,std::vector<uint8_t>(malformed,malformed+6));assert(acks.back().status==R::MALFORMED);
  r.reset();v=frame(1,512);r.accept(v.data(),30,now);r.disconnect();send(r,frame(2,512));assert(acks.back().status==R::OK && r.stats().invalid==1);
  puts("PASS: 100 x 512 milestone; fragmentation, escaping, CRC, size limits, recovery, timeout, sequences, wrap, idle, END_TEST, logging, coalescing, disconnect.");
}

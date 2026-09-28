#include "../src/products/transit/data/ArrivalPayload.h"
#include "../src/platform/transport/PayloadDelivery.h"
#include <cassert>
#include <fstream>
#include <iterator>
#include <iostream>
#include <cstdio>
static std::string complete(std::string body) {
  uint32_t hash=2166136261u;for(unsigned char c:body){hash^=c;hash*=16777619u;}
  char footer[40];snprintf(footer,sizeof(footer),"END\t%zu\t%08X\n",body.size(),hash);return body+footer;
}
int main(int argc,char**argv) {
  assert(argc==2);std::ifstream file(argv[1]);assert(file);
  const std::string data((std::istreambuf_iterator<char>(file)),{});
  ArrivalBoard board;assert(decodeArrivalPayload(data,board)==ArrivalPayloadResult::valid);
  assert(board.platformCount==8);
  const char* directions[]={"East","North","South","West"};
  for(size_t i=0;i<8;++i) {
    assert(board.platforms[i].stationName==(i<4?"Clark/Lake":"Second Hub"));
    assert(board.platforms[i].direction==directions[i%4]);assert(board.platforms[i].arrivalCount>0);
  }
  ArrivalScreenState state;state.setBoard(board,0);
  for(size_t i=1;i<=4;++i){state.nextPlatform(100);assert(state.platform==i%4);}
  state.nextPlatform(200);state.nextStation(300);assert(state.platform==5);
  for(size_t i=1;i<=4;++i){state.nextPlatform(400);assert(state.platform==4+(1+i)%4);}
  state.setBoard(board,500);assert(state.platform==5);state.nextStation(600);assert(state.platform==1);
  for(bool compact:{false,true}) {state.compact=compact;assert(state.pageCount()==(compact?1:2));state.tick(10000);assert(state.platform==1);}
  // Ninth P record and damaged checksums cannot partially replace the retained board.
  const auto footer=data.rfind("END\t");assert(footer!=std::string::npos);
  assert(decodeArrivalPayload(complete(data.substr(0,footer)+"P\tExtra\tThird\n"),board)==ArrivalPayloadResult::invalid);
  assert(board.platformCount==8 && board.platforms[7].direction=="West");
  std::string damaged=data;damaged[5]^=1;assert(decodeArrivalPayload(damaged,board)==ArrivalPayloadResult::invalid);
  for(size_t chunk:{size_t(20),size_t(244)}) {
    uint8_t header[19];PayloadDelivery::envelope(header,2,0x100000002ULL);
    PayloadDelivery::put16(header+11,data.size());PayloadDelivery::put16(header+13,(data.size()+chunk-1)/chunk);
    PayloadDelivery::put32(header+15,PayloadDelivery::crc32(reinterpret_cast<const uint8_t*>(data.data()),data.size()));
    PayloadDelivery::Frame frame;assert(frame.begin(header,19,0));
    for(size_t offset=0;offset<data.size();offset+=chunk)assert(frame.accept(reinterpret_cast<const uint8_t*>(data.data()+offset),std::min(chunk,data.size()-offset)));
    assert(frame.ready);assert(decodeArrivalPayload(std::string(reinterpret_cast<char*>(frame.data),frame.bytes),board)==ArrivalPayloadResult::valid);
  }
  std::cout<<"PASS Swift eight-platform payload, navigation, standard/compact paging, ninth rejection, checksum and P1 chunking\n";
}

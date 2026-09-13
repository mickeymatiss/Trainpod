#include "../src/products/transit/data/ArrivalPayload.h"
#include "../src/platform/transport/PayloadDelivery.h"
#include <cassert>
#include <fstream>
#include <iostream>
#include <iterator>
#include <cstdio>

static std::string complete(const std::string& body) {
  uint32_t hash=2166136261u;
  for (unsigned char c:body) { hash^=c; hash*=16777619u; }
  char footer[40]; snprintf(footer,sizeof(footer),"END\t%zu\t%08X\n",body.size(),hash);
  return body+footer;
}
int main(int argc, char** argv) {
  for (size_t count=1;count<=4;++count) {
    std::string body="TP2\nGrand\n";
    for(size_t i=0;i<count;++i)
      body+="P\t"+std::string(i%2 ? "Outbound" : "Inbound")+"\t"+(i<2 ? "Grand" : "Chicago")+"\nA\tRed\tC60C30\tHoward\t2\n";
    ArrivalBoard board;
    assert(decodeArrivalPayload(complete(body),board)==ArrivalPayloadResult::valid);
    assert(board.platformCount==count);
    ArrivalScreenState state; state.setBoard(board,0);
    for(size_t i=0;i<count;++i) {
      assert(board.platforms[i].stationName==(i<2 ? "Grand" : "Chicago"));
    }
    for(size_t i=0;i<std::min(count,size_t(2));++i) state.nextPlatform(100);
    assert(state.platform==0);
    state.nextPlatform(100); const auto saved=state.current().direction;
    state.setBoard(board,200); assert(state.current().direction==saved);
    const auto previous=board.platformCount;
    assert(decodeArrivalPayload(complete(body)+"corrupt",board)==ArrivalPayloadResult::invalid);
    assert(board.platformCount==previous);
  }
  ArrivalBoard legacy;
  assert(decodeArrivalPayload(complete("TP2\nGrand\nP\tNorth\nP\tSouth\n"),legacy)==ArrivalPayloadResult::valid);
  assert(legacy.platformCount==2 && legacy.platforms[1].stationName=="Grand");
  assert(legacy.platforms[0].distanceMiles.empty());
  ArrivalBoard distances;
  assert(decodeArrivalPayload(complete("TP2\nGrand\nP\tNorth\tGrand\t0.0\nP\tSouth\tGrand\t\n"),distances)==ArrivalPayloadResult::valid);
  assert(distances.platforms[0].distanceMiles=="0.0" && distances.platforms[1].distanceMiles.empty());
  for(const auto& bad : {"-1.0", "nan", "1,2", "1.23", "10000.0"}) {
    assert(decodeArrivalPayload(complete(std::string("TP2\nGrand\nP\tNorth\tGrand\t")+bad+"\n"),distances)==ArrivalPayloadResult::invalid);
    assert(distances.platformCount==2);
  }
  ArrivalScreenState state; state.setBoard(legacy,0); state.nextPlatform(1);
  ArrivalBoard replacement;
  assert(decodeArrivalPayload(complete("TP2\nChicago\nP\tLoop\tChicago\n"),replacement)==ArrivalPayloadResult::valid);
  state.setBoard(replacement,2); assert(state.platform==0 && state.current().stationName=="Chicago");
  assert(decodeArrivalPayload(complete("TP2\nGrand\nP\tN\nP\tS\nP\tE\nP\tW\nP\tLoop\n"),replacement)==ArrivalPayloadResult::invalid);
  assert(replacement.platformCount==1);
  if(argc>1) {
    std::ifstream input(argv[1]); std::string data((std::istreambuf_iterator<char>(input)),{});
    ArrivalBoard phone;
    assert(decodeArrivalPayload(data,phone)==ArrivalPayloadResult::valid);
    assert(phone.platformCount==4);
    assert(phone.platforms[0].stationName=="Grand" && phone.platforms[2].stationName=="Chicago");
    assert(phone.platforms[0].distanceMiles=="0.7" && phone.platforms[2].distanceMiles=="1.2");
    for(size_t i=0;i<4;++i) assert(phone.platforms[i].arrivalCount==3);
    // Exercise the unchanged BLE framing with the actual Swift payload.
    const size_t chunkSize=20, chunks=(data.size()+chunkSize-1)/chunkSize;
    uint8_t header[19]; PayloadDelivery::envelope(header,2,(uint64_t(1)<<32)|2);
    PayloadDelivery::put16(header+11,data.size()); PayloadDelivery::put16(header+13,chunks);
    PayloadDelivery::put32(header+15,PayloadDelivery::crc32(reinterpret_cast<const uint8_t*>(data.data()),data.size()));
    PayloadDelivery::Frame frame; assert(frame.begin(header,sizeof(header),0));
    for(size_t offset=0;offset<data.size();offset+=chunkSize) {
      assert(!frame.ready);
      assert(frame.accept(reinterpret_cast<const uint8_t*>(data.data()+offset),std::min(chunkSize,data.size()-offset)));
    }
    assert(frame.ready);
    assert(decodeArrivalPayload(std::string(reinterpret_cast<const char*>(frame.data),frame.bytes),phone)==ArrivalPayloadResult::valid);
    assert(phone.platformCount==4);
  }
  std::cout<<"PASS 1-4 pages, within-station wrap, station identity, refresh preservation/reset, legacy TP2, atomic rejection, phone fixture\n";
}

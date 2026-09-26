#include "../src/products/transit/data/ArrivalPayload.h"
#include "PayloadTestSupport.h"
#include <cassert>
#include <iostream>
int main() {
  ArrivalBoard board;
  assert(decodeArrivalPayload(complete("TP2\nMorgan\nP\tWest\nA\tGreen\t009B3A\tHarlem/Lake\t10\nA\tPink\tE27EA6\t54th/Cermak\t2\nP\tEast\n"),board)==ArrivalPayloadResult::valid);
  assert(board.platformCount==2 && board.platforms[0].arrivals[0].eta==2);
  assert(board.platforms[1].arrivalCount==0);
  for(bool compact:{false,true}) for(size_t count=0;count<=9;++count) {
    board.platforms[0].arrivalCount=count;
    ArrivalScreenState s; s.compact=compact; s.setBoard(board,100);
    size_t expected=std::max(size_t(1),(count+(compact?5:2))/(compact?6:3));
    assert(s.pageCount()==expected); s.tick(8099); assert(s.page==0);
    s.tick(8100); assert(s.page==(expected>1?1:0));
    if(expected>1) {s.tick(14099);assert(s.page==1);s.tick(14100);assert(s.page==2%expected);}
    s.nextPlatform(15000); assert(s.platform==1 && s.page==0 && s.received==100);
  }
  ArrivalScreenState s; s.setBoard(board,100); s.tick(8100); assert(s.page==1);
  s.setBoard(board,9000); assert(s.page==1 && s.pageStarted==8100 && s.received==9000);
  board.platforms[0].arrivalCount=1; s.setBoard(board,9100); assert(s.page==0 && s.pageStarted==9100);
  assert(s.ageMinutes(129099)==1 && s.ageMinutes(129100)==2);
  s.tick(15000); assert(s.clockFrame==1);
  board.platforms[0].arrivalCount=9; ArrivalScreenState w; w.setBoard(board,UINT32_MAX-2000);
  w.tick(uint32_t(UINT32_MAX-2000+8000u)); assert(w.page==1);
  ArrivalScreenState delayed; delayed.setBoard(board,0); delayed.tick(48000); assert(delayed.page==1 && delayed.pageStarted==48000);
  const auto saved=board.platforms[0].arrivals[0].destination;
  assert(decodeArrivalPayload(complete("TP2\nMorgan\nP\tWest\nA\tGreen\tINVALID\tBad\t2\n"),board)==ArrivalPayloadResult::invalid);
  assert(decodeArrivalPayload("TP2\n!\n",board)==ArrivalPayloadResult::unavailable);
  assert(decodeArrivalPayload("TP2\nMorgan\nP\tWest",board)==ArrivalPayloadResult::invalid);
  assert(decodeArrivalPayload("",board)==ArrivalPayloadResult::invalid);
  assert(board.platforms[0].arrivals[0].destination==saved);
  std::cout<<"PASS standard/compact 0-9, 8s/6s dwell, replacement, delayed ticks, freshness, wrap and rejection\n";
}

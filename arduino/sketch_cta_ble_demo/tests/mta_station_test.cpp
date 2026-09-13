#include "../src/products/transit/data/ArrivalPayload.h"
#include <cassert>
#include <cstdio>
#include <iostream>
int main() {
  const std::string body = "TP2\nTimes Sq-42 St\nP\tMTA\tTimes Sq-42 St\t100\tft\nP\tMTA\t42 St-Bryant Pk\t0.4\tmi\n";
  uint32_t hash=2166136261u;
  for(unsigned char c:body) { hash^=c; hash*=16777619u; }
  char footer[40]; snprintf(footer,sizeof(footer),"END\t%zu\t%08X\n",body.size(),hash);
  ArrivalBoard board;
  assert(decodeArrivalPayload(body+footer,board)==ArrivalPayloadResult::valid);
  assert(board.platformCount==2 && board.platforms[0].arrivalCount==0);
  assert(board.platforms[0].distanceValue=="100" && board.platforms[0].distanceUnit=="ft");
  ArrivalScreenState state; state.setBoard(board,0);
  state.nextStation(1); assert(state.current().stationName=="42 St-Bryant Pk");
  state.nextStation(2); assert(state.current().stationName=="Times Sq-42 St");
  assert(decodeArrivalPayload(body+"broken\n",board)==ArrivalPayloadResult::invalid);
  assert(board.platformCount==2);
  std::cout << "MTA station payload, navigation and corruption checks passed\n";
}

#include "../src/products/transit/data/ArrivalPayload.h"
#include <cassert>
#include <fstream>
#include <iterator>
#include <iostream>
int main(int argc, char** argv) {
  assert(argc == 2);
  std::ifstream input(argv[1]);
  std::string payload((std::istreambuf_iterator<char>(input)), std::istreambuf_iterator<char>());
  ArrivalBoard board;
  assert(decodeArrivalPayload(payload, board) == ArrivalPayloadResult::valid);
  assert(board.platformCount == 4);
  assert(board.platforms[0].arrivalCount == 2 && board.platforms[1].arrivalCount == 1);
  assert(board.platforms[0].direction == "Northbound");
  assert(board.platforms[1].direction == "Southbound");
  assert(board.platforms[2].arrivalCount == 1 && board.platforms[3].arrivalCount == 0);
  assert(board.platforms[0].arrivals[0].routeLabel == "F");
  assert(board.platforms[0].arrivals[0].routeColor == 0xFF6319);
  assert(board.platforms[0].arrivals[0].destination == "Northbound");
  ArrivalScreenState state; state.setBoard(board,0);
  state.nextPlatform(1); assert(state.current().direction == "Southbound");
  state.nextStation(2); assert(state.current().direction == "Southbound");
  assert(state.current().stationName == "Two");
  payload[10] ^= 1;
  assert(decodeArrivalPayload(payload, board) == ArrivalPayloadResult::invalid);
  std::cout << "iOS live-arrival payload accepted by unchanged device decoder; checksum and station navigation pass.\n";
}

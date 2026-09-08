#include "../ArrivalPayload.h"
#include <cassert>
#include <iostream>

int main() {
  ArrivalBoard board;
  assert(decodeArrivalPayload("TP2\nMorgan\nP\tWest\nA\tGreen\t009B3A\tHarlem/Lake\t10\nA\tPink\tE27EA6\t54th/Cermak\t2\nP\tEast\n", board) == ArrivalPayloadResult::valid);
  assert(board.platformCount == 2 && board.platforms[0].arrivals[0].eta == 2);
  assert(board.platforms[0].arrivals[0].destination == "54th/Cermak");
  assert(board.platforms[1].arrivalCount == 0);
  for (size_t count=0; count<=9; ++count) {
    board.platforms[0].arrivalCount = count;
    ArrivalScreenState state;
    state.setBoard(board, 100);
    const size_t expected = count <= 3 ? 1 : count <= 6 ? 2 : 3;
    assert(state.pageCount() == expected);
    state.tick(5099); assert(state.page == 0);
    state.tick(5100); assert(state.page == (expected > 1 ? 1 : 0));
    state.nextPlatform(6000); assert(state.page == 0 && state.platform == 1 && state.pageStarted == 6000);
    state.nextPlatform(7000); assert(state.page == 0 && state.platform == 0);
    state.tick(11999); assert(state.page == 0);
    state.tick(12000); assert(state.page == (expected > 1 ? 1 : 0));
  }
  ArrivalScreenState state;
  state.setBoard(board, 100);
  assert(state.ageMinutes(120099) == 1 && state.ageMinutes(120100) == 2);
  state.tick(14999); assert(state.clockFrame == 0);
  state.tick(15000); assert(state.clockFrame == 1);
  state.nextPlatform(15001);
  assert(state.received == 100); // Switching pages does not make old data fresh.
  state.setBoard(board, 16000);
  assert(state.platform == 1 && state.page == 0 && state.received == 16000);
  state.nextPlatform(16001);
  state.setBoard(board, UINT32_MAX-2000);
  state.tick(2999); assert(state.page == 1); // millis wrap.
  const auto saved = board.platforms[0].arrivals[0].destination;
  assert(decodeArrivalPayload("TP2\nMorgan\nP\tWest\nA\tGreen\tINVALID\tBad\t2\n", board) == ArrivalPayloadResult::invalid);
  assert(board.platforms[0].arrivals[0].destination == saved);
  assert(decodeArrivalPayload("TP2\n!\n", board) == ArrivalPayloadResult::unavailable);
  assert(board.platforms[0].arrivals[0].destination == saved);
  assert(decodeArrivalPayload("TP2\nMorgan\nP\tWest", board) == ArrivalPayloadResult::invalid);
  assert(decodeArrivalPayload("", board) == ArrivalPayloadResult::invalid);
  std::cout << "PASS pagination 0-9, 5s timing, platform reset, 15s clock, stale age, millis wrap, parsing and cached-data preservation\n";
}

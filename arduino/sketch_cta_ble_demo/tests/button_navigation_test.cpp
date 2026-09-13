#include "../src/products/transit/input/ButtonTap.h"
#include "../src/products/transit/data/ArrivalDisplay.h"
#include <cassert>
#include <iostream>

int main() {
  using Action = ButtonTap::Action;
  ButtonTap tap;
  assert(tap.press(100)==Action::None);
  assert(tap.tick(400)==Action::None);
  assert(tap.tick(401)==Action::Platform);
  assert(tap.tick(500)==Action::None);
  assert(tap.press(600)==Action::None);
  assert(tap.press(850)==Action::Station);
  assert(tap.tick(1200)==Action::None);
  assert(tap.press(1300)==Action::None);
  assert(tap.press(1601)==Action::Platform);
  assert(tap.tick(1902)==Action::Platform);
  tap.press(2000); tap.reset(); assert(tap.tick(3000)==Action::None);
  assert(tap.press(UINT32_MAX-100)==Action::None);
  assert(tap.press(50)==Action::Station);
  assert(tap.press(UINT32_MAX-100)==Action::None);
  assert(tap.tick(201)==Action::Platform);

  ArrivalBoard board; board.platformCount=4;
  for(size_t i=0;i<4;++i) {
    board.platforms[i].stationName=i<2 ? "Grand" : "Chicago";
    board.platforms[i].direction=i%2 ? "South" : "North";
  }
  ArrivalScreenState state; state.setBoard(board,0);
  state.nextPlatform(1); assert(state.platform==1);
  state.nextPlatform(2); assert(state.platform==0);
  state.nextStation(3); assert(state.platform==2);
  state.nextPlatform(4); assert(state.platform==3);
  state.nextStation(5); assert(state.platform==1);
  board.platformCount=3; state.setBoard(board,6);
  state.nextStation(7); assert(state.platform==2); // South absent: first platform.
  state.nextPlatform(8); assert(state.platform==2); // One platform: stay here.
  state.nextStation(9); assert(state.platform==0);
  board.platformCount=1; state.setBoard(board,10);
  state.nextPlatform(11); state.nextStation(12); assert(state.platform==0);
  state.page=2; state.nextPlatform(13); assert(state.page==0 && state.pageStarted==13);
  ArrivalScreenState empty; empty.nextPlatform(1); empty.nextStation(2);
  assert(empty.platform==0);
  std::cout<<"PASS single/double timing, no extra single after double, reset, millis wrap, station/platform navigation, 1/3/4 pages\n";
}

#pragma once
#include "../data/ArrivalDisplay.h"
#include "theme/pallete.h"
struct RenderSnapshot {
  ArrivalScreenState board;
  pallete::Theme theme{};
  uint32_t generation=0, styleRevision=0;
  uint64_t transaction=0;
  int setupState=-1; // -1: ordinary board, otherwise provisioning screen.
  int batteryPercent=-1;
  bool connected=false, suspended=false, buttonDown=false;
};

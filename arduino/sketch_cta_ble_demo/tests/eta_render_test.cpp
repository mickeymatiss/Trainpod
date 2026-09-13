#define TRAINPOD_RENDER_TEST
#include <stdint.h>
#include <cassert>
#include <iostream>
enum class PerformanceMode { ACTIVE };
bool setPerformanceMode(PerformanceMode){return true;}
uint64_t esp_timer_get_time(){return 1000;}
enum class EventCode { DISPLAY_UPDATE_START, DISPLAY_UPDATE_COMPLETE, DISPLAY_UPDATED };
enum class LogLevel { Info };
struct DiagnosticStore {
  static DiagnosticStore& shared(){static DiagnosticStore d;return d;}
  template<class... T> void event(T...){}
  void startupComplete(){}
};
struct MetricsStore {
  static MetricsStore& shared(){static MetricsStore m;return m;}
  void recordBootToData(uint32_t){}
};
struct SerialStub { template<class... T> void printf(T...){} void println(const char*){} } Serial;
#include "../src/products/transit/ui/ArrivalScreen.cpp"
struct ArrivalScreenTest {
  static size_t selected(const ArrivalScreen& s){return s.state.platform;}
  static bool active(const ArrivalScreen& s){return s.platformDip.active;}
};

static void onlyEtas(const Arduino_GFX& gfx) {
  for(const auto& op:gfx.ops) {
    assert(op.kind=="rect" || op.kind=="text");
    assert(op.x>=8 && op.x+op.w<=62);
    // Only the first and third ETA changed. The entire middle row is untouched.
    assert((op.y>=37 && op.y+op.h<=69) || (op.y>=117 && op.y+op.h<=149));
  }
}
int main(){
  assert(etaColor(0)==ETA_BG);
  assert(etaColor(255)==RGB565(0xDD,0xD1,0xBA));
  // Every accepted ETA fits at native size, including italic overhangs.
  Arduino_GFX sizing;
  for(int value=0;value<=9999;++value) {
    int16_t x,y;uint16_t w=0,h=0;
    for(const GFXfont* font : {&FreeSansBoldOblique18pt7b,&FreeSansBoldOblique12pt7b,&FreeSansBoldOblique9pt7b}) {
      sizing.setFont(font);
      sizing.getTextBounds(std::to_string(value).c_str(),0,0,&x,&y,&w,&h);
      if(w<=44 && h<=26) break;
    }
    assert(w<=44 && h<=26);
  }
  Arduino_GFX gfx; ArrivalScreen screen(gfx); screen.begin(0); screen.setConnected(true);
  ArrivalBoard board;board.platformCount=1;
  auto& p=board.platforms[0];p.stationName="Grand";p.direction="North";p.arrivalCount=3;
  p.arrivals[0]={"Red",0xff0000,"Howard",3};
  p.arrivals[1]={"Blue",0x0000ff,"Airport",8};
  p.arrivals[2]={"Pink",0xff00ff,"Loop",14};
  screen.setPlatforms(board,0);screen.tick(0);gfx.ops.clear();
  screen.setPlatforms(board,100);screen.tick(100);assert(gfx.ops.empty());
  p.arrivals[0].eta=2;p.arrivals[2].eta=13;
  screen.setPlatforms(board,200);screen.tick(200);assert(gfx.ops.empty());
  for(uint32_t now=225;now<=450;now+=25){
    gfx.ops.clear();screen.tick(now);assert(gfx.ops.size()==4);onlyEtas(gfx);
  }
  gfx.ops.clear();screen.tick(475);assert(gfx.ops.empty());
  // A periodic invisible clock tick must not repaint the UI.
  screen.tick(15000);assert(gfx.ops.empty());
  // Digit growth/shrink and retargeting stay inside the number rectangles.
  p.arrivals[0].eta=10;screen.setPlatforms(board,15100);screen.tick(15100);
  screen.tick(15125);p.arrivals[0].eta=9;screen.setPlatforms(board,15150);screen.tick(15150);
  for(uint32_t now=15175;now<=15350;now+=25)screen.tick(now);
  onlyEtas(gfx);
  gfx.ops.clear();screen.setPlatforms(board,15400);screen.tick(15400);assert(gfx.ops.empty());
  screen.setConnected(false);screen.tick(15500);
  for(const auto& op:gfx.ops){assert(op.kind!="screen");assert(op.y>=150);}
  // Navigation only transfers composed regions, never a screen/row clear.
  board.platformCount=4;
  for(size_t i=1;i<4;++i) {
    board.platforms[i]=board.platforms[0];
    board.platforms[i].stationName=i<2 ? "Grand" : "Chicago";
    board.platforms[i].direction=i%2 ? "South" : "North";
  }
  screen.setPlatforms(board,16000);screen.tick(16000);gfx.ops.clear();
  screen.nextPlatform(16100);assert(ArrivalScreenTest::selected(screen)==0);
  assert(gfx.ops.empty());
  for(int step=1;step<=5;++step) {
    gfx.ops.clear();screen.tick(16100+35*step);
    assert(ArrivalScreenTest::selected(screen)==(step<3 ? 0:1));
    assert(!gfx.ops.empty());
    for(const auto& op:gfx.ops) {
      assert(op.kind=="bitmap");
      if(op.y<30) assert(op.x==8 && op.w==96); // Station header untouched.
      if(op.y>=150) assert(op.x>=132); // Battery/connection untouched.
    }
  }
  assert(!ArrivalScreenTest::active(screen));gfx.ops.clear();screen.tick(16300);assert(gfx.ops.empty());
  screen.nextStation(16400);
  bool stationHeader=false;
  for(int step=1;step<=5;++step) {
    gfx.ops.clear();screen.tick(16400+35*step);
    for(const auto& op:gfx.ops) {
      assert(op.kind=="bitmap");
      if(op.y<30 && op.x==111) stationHeader=true;
      if(op.y>=150) assert(op.x>=132);
    }
  }
  assert(stationHeader && ArrivalScreenTest::selected(screen)==3);
  screen.nextStation(17000);screen.tick(17035);screen.nextPlatform(17040);
  screen.tick(17070);assert(ArrivalScreenTest::selected(screen)==3);
  screen.tick(17105);assert(ArrivalScreenTest::selected(screen)==0); // Latest target, no queued platform 1.
  screen.tick(17140);screen.tick(17175);
  std::cout<<"PASS actual renderer: unchanged updates draw nothing, concurrent ETA-only rectangles, digit changes, retargeting, clock silence, footer isolation\n";
}

#include "ArrivalScreen.h"
#include "../../../platform/diagnostics/SerialLog.h"
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include "../../../platform/power/PerformanceMode.h"

void ArrivalScreen::logSpringState() {
  if(springLoggedState==springBlock.state) return;
  const char* names[]={"RETRACTED","PRESSING","HELD","RELEASING"};
  if(springBlock.settings.debug)
    DebugLog.printf("SPRING: %s -> %s button=%s target=%.1f current=%.1f\n",
      names[int(springLoggedState)],names[int(springBlock.state)],
      springBlock.pressed?"DOWN":"UP",springBlock.target,springBlock.position);
  springLoggedState=springBlock.state;
}

void ArrivalScreen::clearSpring() {
  springBlock.reset();
  logSpringState();
  springInvalidated=true;
  if(!suspended && springVisible) drawSpring(millis());
}

void ArrivalScreen::buttonChanged(bool pressed,uint32_t now) {
  springPhysicalHeld=pressed;
  // A real input edge takes ownership from a serial simulation.
  springTestHeld=false;
  springBlock.setPressed(pressed,now);
  logSpringState();
  drawSpring(now);
}

void ArrivalScreen::drawSpring(uint32_t now) {
  if(suspended) return;
  springBlock.setPressed(feedbackHeld(),now);
  logSpringState();
  if(!springBlock.moving() && !springVisible && springBlock.position==0) return;
  if(!springInvalidated && !springBlock.moving() && int(springBlock.position+0.5f)==springPaintedPosition) return;
  if(!springInvalidated && uint32_t(now-springLastFrame)<16) return;
  if(!setPerformanceMode(PerformanceMode::ACTIVE)) return;
  springLastFrame=now;
  if(!springCanvas) {
    springCanvas.reset(new Arduino_Canvas(76,22,nullptr));
    if(!springCanvas->begin()) { springCanvas.reset(); return; }
    springInvalidated=true;
  }
  if(springInvalidated) {
    if(!navigationCanvas) {
      navigationCanvas.reset(new Arduino_Canvas(gfx.width(),gfx.height(),nullptr));
      if(!navigationCanvas->begin()) { navigationCanvas.reset(); return; }
    }
    // Recompose normal footer beneath the overlay, including any text or gauge.
    // RAM only: no visible erase frame, and never read back pixels from the TFT.
    auto* previous=drawingTarget;
    drawingTarget=navigationCanvas.get();
    drawFooter(now);
    drawingTarget=previous;
    const auto* source=navigationCanvas->getFramebuffer();
    for(int row=0;row<22;++row)
      std::memcpy(springBackdrop.data()+row*76,
        source+(gfx.height()-22+row)*gfx.width()+gfx.width()-76,76*sizeof(uint16_t));
    springInvalidated=false;
  }
  auto* pixels=springCanvas->getFramebuffer();
  std::memcpy(pixels,springBackdrop.data(),sizeof(springBackdrop));
  const auto& s=springBlock.settings;
  const int x=76-10-s.width;
  const int position=int(springBlock.position+0.5f);
  // Fixed horizontal anchor; the bottom boundary clips the tab's hidden tail.
  springCanvas->fillRoundRect(x,22-position,s.width,s.height,s.radius,0);
  const int dirtyLeft=x-2,dirtyWidth=s.width+4;
  const int dirtyTop=22-s.depth-2,dirtyHeight=s.depth+2;
  for(int row=dirtyTop;row<dirtyTop+dirtyHeight;++row)
    gfx.draw16bitRGBBitmap(gfx.width()-76+dirtyLeft,gfx.height()-22+row,
      pixels+row*76+dirtyLeft,dirtyWidth,1);
  springVisible=position>0;
  springPaintedPosition=position;
}

bool ArrivalScreen::springCommand(const char* command,uint32_t now) {
  if(std::strcmp(command,"spring") && std::strncmp(command,"spring ",7)) return false;
  auto& s=springBlock.settings;
  if(!std::strcmp(command,"spring testdown") || !std::strcmp(command,"spring testup")) {
    springTestHeld=!std::strcmp(command,"spring testdown");
  } else if(!std::strcmp(command,"spring on") || !std::strcmp(command,"spring off")) {
    clearSpring(); s.enabled=!std::strcmp(command,"spring on");
    if(!s.enabled) springTestHeld=false;
  } else if(!std::strcmp(command,"spring debug on") || !std::strcmp(command,"spring debug off")) {
    s.debug=!std::strcmp(command,"spring debug on");
  } else if(!std::strcmp(command,"spring reset")) {
    clearSpring(); springTestHeld=false; s=SpringBlock::Settings{};
  } else if(!std::strcmp(command,"spring") || !std::strcmp(command,"spring status") || !std::strcmp(command,"spring help")) {
    printEffects(!std::strcmp(command,"spring help")); return true;
  } else {
    char key[16],arg[16],extra;
    bool valid=false;
    if(std::sscanf(command,"spring %15s %15s %c",key,arg,&extra)==2) {
      struct Tuner { const char* name;int* field;int low,high; };
      const Tuner tuners[]={{"width",&s.width,4,64},{"height",&s.height,3,32},
        {"depth",&s.depth,1,11},{"radius",&s.radius,0,12},
        {"pressms",&s.pressMs,10,500},{"releasems",&s.releaseMs,10,1000}};
      for(const auto& t:tuners) if(!std::strcmp(key,t.name)) {
        char* end; const long value=std::strtol(arg,&end,10);
        if(*end || value<t.low || value>t.high) {
          InfoLog.printf("ERR spring %s range = %d..%d\n",key,t.low,t.high); return true;
        }
        const int width=t.field==&s.width ? value : s.width;
        const int height=t.field==&s.height ? value : s.height;
        const int depth=t.field==&s.depth ? value : s.depth;
        const int radius=t.field==&s.radius ? value : s.radius;
        if(depth>=height || depth+radius>height || radius*2>height || radius*2>width) {
          InfoLog.println("ERR spring requires height >= depth + radius, depth < height, and radius <= half width/height"); return true;
        }
        clearSpring(); *t.field=int(value);valid=true;break;
      }
    }
    if(!valid) { InfoLog.println("ERR unknown spring command; type spring help"); return true; }
  }
  springBlock.setPressed(feedbackHeld(),now);
  logSpringState(); drawSpring(now);
  InfoLog.printf("OK %s\n",command);
  return true;
}

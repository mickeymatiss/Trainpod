#include "../../../platform/diagnostics/SerialLog.h"
#include "ArrivalScreen.h"
#include "theme/pallete.h"
#include "fonts/ArrivalItalic18.h"
#include <cstring>
#include <cstdio>
#include <cstdlib>

void ArrivalScreen::drawEta(size_t slot,int value,uint8_t opacity,bool /*clear*/) {
  if(etaRimValid[slot] && etaCachedValue[slot]==value) {
    presentEta(slot,opacity);
    return;
  }
  const std::string eta=value<0 ? "" : std::to_string(value);
  surface().setTextWrap(false);
  surface().setTextSize(1);
  const GFXfont* font=&FreeSansBoldOblique18pt7b;
  surface().setFont(font);
  int16_t bx=0,by=0; uint16_t w=0,h=0;
  surface().getTextBounds(eta.c_str(),0,0,&bx,&by,&w,&h);
  renderEffectEta(slot,eta,font,opacity,bx,by,w,h,18);
  etaCachedValue[slot]=value;
}

void ArrivalScreen::presentEta(size_t slot,uint8_t opacity) {
  const uint16_t bg=pallete::arrivalBadge();
  for(int y=0;y<28;++y) for(int x=0;x<50;++x) {
    const int source=(y+2)*54+x+2;
    const auto color=etaPixels[slot][source];
    // The rim and rounded exterior stay at their normal colors throughout.
    const int sx=x+2,sy=y+2;
    const int cx=sx<10 ? 10-sx : sx>=44 ? sx-43 : 0;
    const int cy=sy<10 ? 10-sy : sy>=22 ? sy-21 : 0;
    const bool fixed=etaRimMask[slot][source] || (cx && cy && cx*cx+cy*cy>100);
    etaFrame[y*50+x]=fixed || opacity==255 ? color : DisplayEffects::fade565(color,bg,opacity);
  }
  // Pack the interior contiguously: one address window instead of 28 rows.
  surface().draw16bitRGBBitmap(cellX(slot)+2,cellY(slot)+2,etaFrame.data(),50,28);
}

void ArrivalScreen::renderEffectEta(size_t slot,const std::string& value,const GFXfont* font,uint8_t opacity,int bx,int by,int w,int h,int fontPoints) {
  auto& pixels=etaPixels[slot];
  const uint16_t bg=pallete::arrivalBadge(),fg=pallete::arrivalBadgeText(255);
  // Preserve the rounded badge silhouette even at large bloom radii.
  for(int y=0;y<32;++y) for(int x=0;x<54;++x) {
    if(etaRimValid[slot] && etaRimMask[slot][y*54+x]) continue;
    const int cx=x<10 ? 10-x : x>=44 ? x-43 : 0;
    const int cy=y<10 ? 10-y : y>=22 ? y-21 : 0;
    pixels[y*54+x]=cx && cy && cx*cx+cy*cy>100 ? pallete::background() : bg;
  }
  const int top=cellY(slot);
  // Fit measured ink bounds and all offset layers inside a safe inset rectangle.
  int left=0,right=0,above=0,below=0;
  if(effects.depth) {
    left=std::max(left,-effects.depthX);right=std::max(right,effects.depthX);
    above=std::max(above,-effects.depthY);below=std::max(below,effects.depthY);
  }
  if(effects.bloom) {
    left=std::max(left,effects.radius-effects.biasX);
    right=std::max(right,effects.radius+effects.biasX);
    above=std::max(above,effects.radius-effects.biasY);
    below=std::max(below,effects.radius+effects.biasY);
  }
  const int rim=bezel.enabled && bezel.eta ? bezel.thickness : 0;
  const int clipX=std::max(5,rim+2),clipY=std::max(4,rim);
  const int clipW=54-2*clipX,clipH=32-2*clipY;
  int uniformScale=10000*(fontPoints-1)/fontPoints; // Keep the requested one-point reduction.
  if(w>0) uniformScale=std::min(uniformScale,10000*std::max(1,clipW-left-right)/w);
  if(h>0) uniformScale=std::min(uniformScale,10000*std::max(1,clipH-above-below)/h);
  uniformScale=std::max(1,uniformScale);
  const int inkW=(w*uniformScale+9999)/10000,inkH=(h*uniformScale+9999)/10000;
  const int originX=std::max(clipX+left,std::min((54-inkW)/2,54-clipX-right-inkW));
  const int originY=std::max(clipY+above,std::min((32-inkH)/2,32-clipY-below-inkH));
  etaBounds[slot]={int16_t(cellX(slot)+originX),int16_t(top+originY),uint16_t(inkW),uint16_t(inkH)};
  if(!value.empty() && (etaLoggedValue[slot]!=value || etaLoggedScale[slot]!=uniformScale)) {
    DebugLog.printf("ETA \"%s\" width=%d height=%d xOffset=%d yOffset=%d fontSize=%d scaleX=%d/10000 scaleY=%d/10000 monitorWidth=54 clipWidth=%d clipHeight=%d\n",
      value.c_str(),w,h,bx,by,fontPoints,uniformScale,uniformScale,clipW,clipH);
    etaLoggedValue[slot]=value;etaLoggedScale[slot]=uniformScale;
  }
  // Inverse-sample only when preparing a new cached image. Every visual layer
  // uses this same mask; opacity-only frames never enter this function.
  auto& ink=etaInk;
  ink.fill(0);
  for(int y=0;y<inkH;++y) for(int x=0;x<inkW;++x) {
    const int sourceX=std::min(w-1,((2*x+1)*10000)/(2*uniformScale))+bx;
    const int sourceY=std::min(h-1,((2*y+1)*10000)/(2*uniformScale))+by;
    int pen=0;
    for(unsigned char c:value) {
      if(c<font->first || c>font->last) continue;
      const GFXglyph& g=font->glyph[c-font->first];
      const int gx=sourceX-pen-g.xOffset,gy=sourceY-g.yOffset;
      if(gx>=0 && gx<g.width && gy>=0 && gy<g.height) {
        const int bit=gy*g.width+gx;
        if(pgm_read_byte(font->bitmap+g.bitmapOffset+bit/8)&(0x80>>(bit%8)))
          ink[y*54+x]=1;
      }
      pen+=g.xAdvance;
    }
  }
  auto glyphs=[&](int offsetX,int offsetY,uint16_t color) {
    for(int y=0;y<inkH;++y) for(int x=0;x<inkW;++x) if(ink[y*54+x]) {
      const int px=originX+x+offsetX,py=originY+y+offsetY;
      if(px>=clipX && px<54-clipX && py>=clipY && py<32-clipY)
        pixels[py*54+px]=color;
    }
  };
  if(effects.bloom) {
    const int offsets[][2]={{-1,0},{1,0},{0,-1},{0,1},{-1,-1},{1,-1},{-1,1},{1,1}};
    for(int i=0;i<effects.copies;++i)
      glyphs(offsets[i][0]*effects.radius+effects.biasX,offsets[i][1]*effects.radius+effects.biasY,DisplayEffects::mix(bg,fg,effects.intensity));
  }
  if(effects.depth) {
    // Cache the full-strength darkened layer. Presentation fades the complete
    // image so depth and primary numerals disappear together.
    const uint16_t body=DisplayEffects::scale565(pallete::arrivalBadgeText(255),100-effects.depthDarken);
    glyphs(effects.depthX,effects.depthY,body);
  }
  glyphs(0,0,fg);
  // Cache the rim at its normal color so ETA fades never erase or dim it.
  if(!etaRimValid[slot]) {
    for(int y=0;y<32;++y) for(int x=0;x<54;++x) {
      const bool rim=bezel.eta && bezel.rim(x,y,54,32,10,(uint32_t(cellX(slot))<<16)|uint32_t(top));
      etaRimMask[slot][y*54+x]=rim;
      if(rim) pixels[y*54+x]=bezel.color(x,y,54,32,pallete::arrivalBadge(),pallete::background(),(uint32_t(cellX(slot))<<16)|uint32_t(top));
    }
    etaRimValid[slot]=true;
  }
  presentEta(slot,opacity);
}

void ArrivalScreen::printEffects(bool help) {
  InfoLog.printf("lip %s shadow=%d highlight=%d (1 px)\n",effects.lip?"on":"off",effects.lipShadow,effects.lipHighlight);
  InfoLog.printf("depth %s darken=%d x=%d y=%d (ETA and distance numbers)\n",effects.depth?"on":"off",effects.depthDarken,effects.depthX,effects.depthY);
  InfoLog.printf("bezel %s thickness=%d brightness=%d contrast=%d eta=%d distance=%d route=%d\n",bezel.enabled?"on":"off",bezel.thickness,bezel.brightness,bezel.contrast,bezel.eta,bezel.distance,bezel.route);
  const auto& s=springBlock.settings;
  InfoLog.printf("spring %s width=%d height=%d depth=%d radius=%d pressms=%d releasems=%d debug=%d held=%d current=%.1f\n",s.enabled?"on":"off",s.width,s.height,s.depth,s.radius,s.pressMs,s.releaseMs,s.debug,feedbackHeld(),springBlock.position);
  InfoLog.printf("stable %s (distance gauge)\n",effects.stable?"on":"off");
  InfoLog.printf("bloom %s radius=%d intensity=%d copies=%d x=%d y=%d\n",effects.bloom?"on":"off",effects.radius,effects.intensity,effects.copies,effects.biasX,effects.biasY);
  if(help) InfoLog.println(
    "help | status | reset | all on/off | demo clean/retro/weird\n"
    "lip on/off | lip shadow 0..20 | lip highlight 0..10\n"
    "depth on/off | depth darken 0..60 | depth x 0..2 | depth y 0..2 (ETA and distance numbers)\n"
    "bezel on/off | bezel thickness 1..3 | bezel brightness 0..100 | bezel contrast 0..100 | bezel eta 0/1 | bezel distance 0/1 | bezel route 0/1\n"
    "spring on/off | spring testdown/testup | spring width 4..64 | spring height 3..32 | spring depth 1..11 (<height, upward from bottom) | spring radius 0..12 (<=half height/width; height >= depth+radius) | spring pressms 10..500 | spring releasems 10..1000 | spring debug on/off (requires log debug)\n"
    "stable on/off: preserve the distance gauge during transitions\n"
    "night help: time-based backlight settings (day/night brightness, start/end hours)\n"
    "log info (default) | log debug | log status: serial verbosity\n"
    "bloom on/off | bloom radius 0..3 | bloom intensity 0..50 | bloom copies 4/8 | bloom x -3..3 | bloom y -3..3\n"
    "RAM only. BLE receiver reset: receiver reset. Existing BLE/metrics commands remain available.");
}

bool ArrivalScreen::effectsCommand(const char* command,uint32_t now) {
  if(transitionCommand(command,now)) return true;
  if(springCommand(command,now)) return true;
  if(!std::strcmp(command,"help") || !std::strcmp(command,"status")) {
    transitionCommand(!std::strcmp(command,"help") ? "transition help" : "transition status",now);
    InfoLog.printf("OK %s\n",command); printEffects(!std::strcmp(command,"help")); return true;
  }
  char group[16]={},key[16]={},arg[16]={},extra;
  const int count=std::sscanf(command,"%15s %15s %15s %c",group,key,arg,&extra);
  auto& s=springBlock.settings;
  bool changed=false;
  if(!std::strcmp(command,"reset")) {
    bezel=GaugeBezel{};
    clearSpring(); springTestHeld=false; effects=DisplayEffects{}; s=SpringBlock::Settings{}; changed=true;
  } else if(count==2 && !std::strcmp(group,"demo") && (!std::strcmp(key,"clean") || !std::strcmp(key,"retro") || !std::strcmp(key,"weird"))) {
    clearSpring(); springTestHeld=false; effects=DisplayEffects{}; s=SpringBlock::Settings{};
    effects.bloom=std::strcmp(key,"clean")!=0;
    if(!std::strcmp(key,"retro")) effects.intensity=15;
    if(!std::strcmp(key,"weird")) { effects.radius=3; effects.intensity=40; }
    changed=true;
  } else if(count==2 && (!std::strcmp(key,"on") || !std::strcmp(key,"off"))) {
    const int value=!std::strcmp(key,"on");
    if(!std::strcmp(group,"spring")) { clearSpring(); s.enabled=value; changed=true; }
    if(!std::strcmp(group,"bloom")) { effects.bloom=value; changed=true; }
    if(!std::strcmp(group,"bezel")) { bezel.enabled=value; changed=true; }
    if(!std::strcmp(group,"lip")) { effects.lip=value; changed=true; }
    if(!std::strcmp(group,"depth")) { effects.depth=value; changed=true; }
    if(!std::strcmp(group,"stable")) { effects.stable=value; changed=true; }
    if(!std::strcmp(group,"all")) { clearSpring(); if(!value) springTestHeld=false; bezel.enabled=value; s.enabled=effects.bloom=effects.lip=effects.depth=value; changed=true; }
  } else if(count==3) {
    struct Tuner { const char* group; const char* key; int* value; int low,high; };
    const Tuner tuners[]={
      {"bezel","route",&bezel.route,0,1},
      {"lip","shadow",&effects.lipShadow,0,20},{"lip","highlight",&effects.lipHighlight,0,10},
      {"depth","darken",&effects.depthDarken,0,60},{"depth","x",&effects.depthX,0,2},{"depth","y",&effects.depthY,0,2},
      {"bezel","thickness",&bezel.thickness,1,3},{"bezel","brightness",&bezel.brightness,0,100},{"bezel","contrast",&bezel.contrast,0,100},{"bezel","eta",&bezel.eta,0,1},{"bezel","distance",&bezel.distance,0,1},
      {"bloom","radius",&effects.radius,0,3},{"bloom","intensity",&effects.intensity,0,50},{"bloom","copies",&effects.copies,4,8},{"bloom","x",&effects.biasX,-3,3},{"bloom","y",&effects.biasY,-3,3}};
    for(const auto& t:tuners) if(!std::strcmp(group,t.group) && !std::strcmp(key,t.key)) {
      char* end; const long value=std::strtol(arg,&end,10);
      if(!*arg || *end || value<t.low || value>t.high || (t.value==&effects.copies && value!=4 && value!=8)) {
        if(t.value==&effects.copies) InfoLog.println("ERR bloom copies range = 4 or 8");
        else InfoLog.printf("ERR %s %s range = %d..%d\n",group,key,t.low,t.high);
        return true;
      }
      if(!std::strcmp(group,"spring")) clearSpring();
      *t.value=int(value); changed=true; break;
    }
  }
  if(!changed) {
    if(!std::strcmp(group,"spring") || !std::strcmp(group,"lip") || !std::strcmp(group,"depth") || !std::strcmp(group,"bezel") || !std::strcmp(group,"bloom") || !std::strcmp(group,"stable") || !std::strcmp(group,"demo") || !std::strcmp(group,"all")) {
      InfoLog.println("ERR unknown command\ntype \"help\""); return true;
    }
    return false;
  }
  if(count==3) InfoLog.printf("OK %s %s = %s\n",group,key,arg);
  else InfoLog.printf("OK %s\n",command);
  // One composed redraw on tuning; animation frames retain small dirty regions.
  themeChanged(now);
  return true;
}

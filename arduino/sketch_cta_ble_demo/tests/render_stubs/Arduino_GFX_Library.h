#pragma once
#include <stdint.h>
#include <string>
#include <vector>
#include <algorithm>
#include <cstdio>
#define PROGMEM
#define RGB565(r,g,b) ((((r)&0xf8)<<8)|(((g)&0xfc)<<3)|((b)>>3))
struct GFXglyph { uint16_t bitmapOffset; uint8_t width,height,xAdvance; int8_t xOffset,yOffset; };
struct GFXfont { uint8_t* bitmap; GFXglyph* glyph; uint16_t first,last; uint8_t yAdvance; };
class String {
public:
  std::string s;
  String(const char* p):s(p) {} String(std::string p):s(p) {}
  size_t length() const { return s.size(); }
  void remove(size_t i) { s.erase(i); }
  String operator+(const char* p) const { return String(s+p); }
  String& operator+=(const char* p) { s+=p;return *this; }
};
struct RenderOp { std::string kind; int x,y,w,h; uint16_t color; };
class Arduino_GFX {
public:
  std::vector<RenderOp> ops;
  std::vector<uint16_t> bitmap;
  unsigned boundsCalls=0;
  const GFXfont* font=nullptr; uint8_t scale=1; int cx=0,cy=0; uint16_t color=0;
  int width()const{return 320;} int height()const{return 172;}
  void setFont(const GFXfont* f){font=f;} void setTextSize(uint8_t s){scale=s;}
  void setTextWrap(bool){} void setTextColor(uint16_t c){color=c;}
  void setCursor(int x,int y){cx=x;cy=y;}
  void getTextBounds(const String& s,int x,int y,int16_t* bx,int16_t* by,uint16_t* w,uint16_t* h) {
    ++boundsCalls;
    if(!font) { *bx=x;*by=y;*w=s.length()*6*scale;*h=8*scale;return; }
    int left=10000,top=10000,right=-10000,bottom=-10000;
    for(unsigned char c:s.s) {
      if(!font || c<font->first || c>font->last) continue;
      const auto& g=font->glyph[c-font->first];
      if(g.width && g.height) {
        left=std::min(left,x+g.xOffset*scale);top=std::min(top,y+g.yOffset*scale);
        right=std::max(right,x+(g.xOffset+g.width)*scale);bottom=std::max(bottom,y+(g.yOffset+g.height)*scale);
      }
      x+=g.xAdvance*scale;
    }
    if(right<left){*bx=x;*by=y;*w=*h=0;return;}
    *bx=left;*by=top;*w=right-left;*h=bottom-top;
  }
  void print(const String& s){int16_t x,y;uint16_t w,h;getTextBounds(s,cx,cy,&x,&y,&w,&h);ops.push_back({"text",x,y,w,h,color});}
  void fillRect(int x,int y,int w,int h,uint16_t c){ops.push_back({"rect",x,y,w,h,c});}
  void fillScreen(uint16_t c){ops.push_back({"screen",0,0,320,172,c});}
  void fillRoundRect(int x,int y,int w,int h,int,uint16_t c){ops.push_back({"capsule",x,y,w,h,c});}
  void drawFastHLine(int x,int y,int w,uint16_t c){ops.push_back({"line",x,y,w,1,c});}
  void drawFastVLine(int x,int y,int h,uint16_t c){ops.push_back({"line",x,y,1,h,c});}
  void fillCircle(int x,int y,int r,uint16_t c){ops.push_back({"circle",x-r,y-r,2*r,2*r,c});}
  void drawRect(int x,int y,int w,int h,uint16_t c){ops.push_back({"outline",x,y,w,h,c});}
  void fillTriangle(int x,int y,int,int,int,int,uint16_t c){ops.push_back({"triangle",x,y,1,1,c});}
  void drawLine(int x,int y,int,int,uint16_t c){ops.push_back({"line",x,y,1,1,c});}
  void draw16bitRGBBitmap(int x,int y,uint16_t* p,int w,int h){ops.push_back({"bitmap",x,y,w,h,0});bitmap.assign(p,p+w*h);}
};
class Arduino_Canvas : public Arduino_GFX {
public:
  Arduino_Canvas(int,int,Arduino_GFX*){}
  bool begin(){pixels.resize(320*172);return true;}
  uint16_t* getFramebuffer(){return pixels.data();}
  std::vector<uint16_t> pixels;
};

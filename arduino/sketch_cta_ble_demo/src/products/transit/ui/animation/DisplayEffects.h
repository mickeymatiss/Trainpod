#pragma once
#include <stdint.h>
#include <algorithm>

struct DisplayEffects {
  int stable=1;
  int lip=1, lipShadow=10, lipHighlight=5;
  int depth=1, depthDarken=30, depthX=1, depthY=1;
  int bloom=1, radius=1, intensity=18, copies=4, biasX=0, biasY=0;
  static uint16_t mix(uint16_t a,uint16_t b,int percent) {
    return (((((a>>11)&31)*(100-percent)+((b>>11)&31)*percent)/100)<<11) |
           (((((a>>5)&63)*(100-percent)+((b>>5)&63)*percent)/100)<<5) |
           (((a&31)*(100-percent)+(b&31)*percent)/100);
  }
  static uint16_t scale565(uint16_t color,int percent) {
    const int r=std::min(31,(((color>>11)&31)*percent+50)/100);
    const int g=std::min(63,(((color>>5)&63)*percent+50)/100);
    const int b=std::min(31,((color&31)*percent+50)/100);
    return (r<<11)|(g<<5)|b;
  }
  static uint16_t fade565(uint16_t color,uint16_t background,uint8_t opacity) {
    const int r=(((color>>11)&31)*opacity+((background>>11)&31)*(255-opacity)+127)/255;
    const int g=(((color>>5)&63)*opacity+((background>>5)&63)*(255-opacity)+127)/255;
    const int b=((color&31)*opacity+(background&31)*(255-opacity)+127)/255;
    return (r<<11)|(g<<5)|b;
  }
};

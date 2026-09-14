#pragma once
#include "DisplayEffects.h"

// Shared uniform inset rim geometry, including the ETA cache.
struct GaugeBezel {
  int enabled=1,eta=1,distance=1,route=1,thickness=2,brightness=50,contrast=40;
  static bool inside(int x,int y,int w,int h,int r) {
    if(x<0 || y<0 || x>=w || y>=h) return false;
    const int dx=x<r ? r-1-x : x>=w-r ? x-(w-r) : 0;
    const int dy=y<r ? r-1-y : y>=h-r ? y-(h-r) : 0;
    return dx*dx+dy*dy<=r*r;
  }
  bool rim(int x,int y,int w,int h,int radius,uint32_t =0) const {
    if(!enabled || !inside(x,y,w,h,radius)) return false;
    return !inside(x-thickness,y-thickness,w-2*thickness,h-2*thickness,std::max(0,radius-thickness));
  }
  uint16_t color(int x,int y,int w,int h,uint16_t badge,uint16_t background,uint32_t =0) const {
    const uint16_t base=DisplayEffects::mix(badge,background,brightness);
    // Use the theme's lighter/darker surface as lighting endpoints, including
    // inverted themes. No fixed highlight, shadow, or rim colors.
    const auto luminance=[](uint16_t c) {
      return 2126*((c>>11)&31)*255/31 +
             7152*((c>>5)&63)*255/63 + 722*(c&31)*255/31;
    };
    const bool backgroundLighter=luminance(background)>=luminance(badge);
    const uint16_t light=backgroundLighter ? background : badge;
    const uint16_t dark=backgroundLighter ? badge : background;
    const uint16_t original=DisplayEffects::mix(base,x*h+y*w<w*h ? light : dark,contrast);
    return original;
  }
};

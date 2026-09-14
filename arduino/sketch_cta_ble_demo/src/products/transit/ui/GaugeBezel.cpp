#include "ArrivalScreen.h"
#include "theme/pallete.h"

void ArrivalScreen::drawGaugeBezel(int left,int top,int width,int height,int radius) {
  drawGaugeBezel(left,top,width,height,radius,pallete::arrivalBadge());
}

void ArrivalScreen::drawGaugeBezel(int left,int top,int width,int height,int radius,uint16_t baseColor) {
  if(!bezel.enabled) return;
  const uint32_t id=(uint32_t(left)<<16)|uint32_t(top);
  // Batch adjacent rim pixels rather than issuing one display write per pixel.
  for(int y=0;y<height && top+y<surface().height();++y) {
    int start=-1; uint16_t runColor=0;
    for(int x=0;x<=width;++x) {
      const bool rim=x<width && bezel.rim(x,y,width,height,radius,id);
      const uint16_t color=rim ? bezel.color(x,y,width,height,baseColor,pallete::background(),id) : 0;
      if(start>=0 && (!rim || color!=runColor)) {
        surface().drawFastHLine(left+start,top+y,x-start,runColor); start=-1;
      }
      if(rim && start<0) { start=x;runColor=color; }
    }
  }
}

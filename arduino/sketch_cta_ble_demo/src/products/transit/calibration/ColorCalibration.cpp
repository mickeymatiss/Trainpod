#include "ColorCalibration.h"
#if KEYTRAIN_COLOR_CALIBRATION
#include <Arduino.h>
#include "../../../platform/power/BacklightFade.h"
#include "../ui/DisplayController.h"
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <cctype>
namespace {
BacklightFade* light=nullptr;
bool running=false;
uint8_t priorBrightness=0;
uint32_t lastHeartbeat=0,lastAcknowledged=0;
void stop() {
  if(running) {
    running=false;DisplayController::setCalibration(false);
    light->setImmediate(priorBrightness);
  }
  Serial.println("CS STOP");
}
}
namespace ColorCalibration {
void begin(BacklightFade& backlight) { light=&backlight; }
bool active() { return running; }
bool command(const char* text) {
  if(std::strncmp(text,"cs ",3)) return false;
  if(!std::strcmp(text,"cs hello")) { Serial.println("CS HELLO 1 waveshare_c6_1_47_st7789_v1 80");return true; }
  if(!std::strcmp(text,"cs stop")) { stop();return true; }
  if(!light) { Serial.println("CS ERROR not_ready");return true; }
  if(!std::strcmp(text,"cs start")) {
    if(!running) priorBrightness=light->level();
    running=true;lastHeartbeat=millis();lastAcknowledged=0;
    light->setImmediate(80);DisplayController::setCalibration(true,0,0);
    Serial.println("CS START 80");return true;
  }
  if(!running) { Serial.println("CS ERROR inactive");return true; }
  if(!std::strcmp(text,"cs ping")) { lastHeartbeat=millis();Serial.println("CS PONG");return true; }
  char sequenceText[8]={},hex[8]={},extra=0;
  if(std::sscanf(text,"cs show %7s %7s %c",sequenceText,hex,&extra)==2 && std::strlen(sequenceText)<=6 && std::strlen(hex)==6) {
    for(char c:sequenceText) if(c && !std::isdigit(static_cast<unsigned char>(c))) { Serial.println("CS ERROR command");return true; }
    for(char c:hex) if(c && !std::isxdigit(static_cast<unsigned char>(c))) { Serial.println("CS ERROR command");return true; }
    const auto seq=std::strtoul(sequenceText,nullptr,10),rgb=std::strtoul(hex,nullptr,16);
    if(seq>0 && seq<=999999 && rgb<=0xFFFFFF) {
      lastHeartbeat=millis();DisplayController::setCalibration(true,uint32_t(rgb),uint32_t(seq));return true;
    }
  }
  Serial.println("CS ERROR command");return true;
}
void tick() {
  if(!running) return;
  if(uint32_t(millis()-lastHeartbeat)>15000) { stop();return; }
  const auto shown=DisplayController::calibrationShown();
  if(shown && shown!=lastAcknowledged) {
    lastAcknowledged=shown;Serial.printf("CS SHOWN %lu\n",(unsigned long)shown);
  }
}
}
#endif

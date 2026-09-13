#include "DeviceHardware.h"
Arduino_GFX* deviceDisplay() {
  // Construct before the product binds its renderer, independent of link order.
  static Arduino_DataBus* bus = new Arduino_ESP32SPI(LCD_DC, LCD_CS, LCD_SCK, LCD_MOSI);
  static Arduino_GFX* gfx = new Arduino_ST7789(bus, LCD_RST, 0, true, 172, 320, 34, 0, 34, 0);
  return gfx;
}

#pragma once
#include <Arduino_GFX_Library.h>
// Current board wiring and LCD configuration; no product rendering here.
#define LCD_DC 15
#define LCD_CS 14
#define LCD_SCK 7
#define LCD_MOSI 6
#define LCD_RST 21
#define LCD_BL 22
#define BUTTON_PIN 9

Arduino_GFX* deviceDisplay();

#pragma once

// Application-loop owned; NVS writes never run in a BLE callback.
namespace DisplayMode {
void begin();
bool compact();
bool store(bool compact);
}

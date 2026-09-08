#pragma once
#include <Arduino.h>
void setupBleIntegration(void (*onRefreshStarted)() = nullptr);
void pollBleIntegration();
bool bleIsConnected();
bool bleWakeTestEnabled();
bool takeTransitPayload(String& payload);
bool transitRefreshPending();
void finishTransitRefresh(bool success);
bool takeTransitRefreshFailure();

#pragma once
#include <Arduino.h>
void setupBleIntegration(void (*onRefreshStarted)() = nullptr);
void pollBleIntegration();
bool bleIsConnected();
bool bleIsReady();
bool bleWakeTestEnabled();
bool takeTransitPayload(String& payload);
bool transitRefreshPending();
void finishTransitRefresh(bool success);
bool takeTransitRefreshFailure();
void setTransitRefreshPaused(bool paused);

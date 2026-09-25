#pragma once
#include <Arduino.h>
void setupBleIntegration(void (*onUiColorChanged)() = nullptr);
void pollBleIntegration();
void openBleManualWindow();
bool bleIsConnected();
bool bleIsReady();
bool bleWakeTestEnabled();
bool bleSessionIsActive();
bool takeTransitPayload(String& payload, uint64_t& transactionId);
void acknowledgeTransitApplied(uint64_t transactionId, uint16_t bytes);
void rejectTransitPayload(uint64_t transactionId, uint8_t error, uint16_t bytes);
bool transitRefreshPending();
void finishTransitRefresh(bool success);
bool takeTransitRefreshFailure();
void setTransitRefreshPaused(bool paused);

// One update episode includes connection setup and bounded transport retransmits.
enum class TransitUpdateReason { STARTUP, REFRESH, RETRY, USER_REQUEST };
void runTransitUpdate(TransitUpdateReason reason);
void transitUpdateStage(uint64_t transaction,const char* stage,uint32_t generation=0);

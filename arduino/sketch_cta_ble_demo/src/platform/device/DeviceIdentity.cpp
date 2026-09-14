#include "DeviceIdentity.h"
#include <nvs.h>
#include <esp_random.h>
#include <bootloader_random.h>

namespace {
String identity;
bool attempted = false;
// Own namespace: ordinary UI, metrics and receive-stat resets must not erase it.
constexpr const char* storageNamespace = "trainpod";
constexpr const char* storageKey = "deviceId";
bool valid(const char* value, size_t size) {
  // Preserve earlier 32-bit IDs if provisioned; new IDs use 128 random bits.
  if ((size != 12 && size != 36) || strncmp(value, "TP-", 3) != 0 || value[size-1] != '\0') return false;
  for (size_t i = 3; i < size-1; ++i)
    if (!((value[i] >= '0' && value[i] <= '9') || (value[i] >= 'A' && value[i] <= 'F'))) return false;
  return true;
}
}

bool DeviceIdentity::begin() {
  if (attempted) return identity.length() != 0;
  attempted = true;
  nvs_handle_t handle;
  esp_err_t error = nvs_open(storageNamespace, NVS_READWRITE, &handle);
  if (error != ESP_OK) {
    Serial.printf("[IDENTITY] Storage unavailable: %d\n", int(error));
    return false;
  }
  char value[36] = {};
  size_t size = sizeof(value);
  error = nvs_get_str(handle, storageKey, value, &size);
  if (error == ESP_ERR_NVS_NOT_FOUND) {
    Serial.println("[IDENTITY] No stored ID found");
    uint8_t bytes[16];
    // Enable hardware entropy explicitly before any RF or ADC users start.
    bootloader_random_enable();
    esp_fill_random(bytes, sizeof(bytes));
    bootloader_random_disable();
    memcpy(value, "TP-", 3);
    const char* hex = "0123456789ABCDEF";
    for (size_t i = 0; i < sizeof(bytes); ++i) {
      value[3 + 2*i] = hex[bytes[i] >> 4];
      value[4 + 2*i] = hex[bytes[i] & 15];
    }
    Serial.printf("[IDENTITY] Generated Device ID: %s\n", value);
    error = nvs_set_str(handle, storageKey, value);
    if (error == ESP_OK) error = nvs_commit(handle);
    if (error == ESP_OK) {
      char verified[36] = {};
      size_t length = sizeof(verified);
      error = nvs_get_str(handle, storageKey, verified, &length);
      if (error == ESP_OK && strcmp(value, verified) != 0) error = ESP_FAIL;
    }
    if (error == ESP_OK) Serial.println("[IDENTITY] Device ID persisted");
    size = sizeof(value);
  }
  nvs_close(handle);
  // Wrong type, unreadable or malformed existing records are preserved, never replaced.
  if (error != ESP_OK || !valid(value, size)) {
    Serial.printf("[IDENTITY] Identity unavailable; stored record preserved (error %d)\n", int(error));
    return false;
  }
  identity = value;
  Serial.printf("[IDENTITY] Device ID: %s\n", identity.c_str());
  return true;
}

String DeviceIdentity::getDeviceId() { return identity; }

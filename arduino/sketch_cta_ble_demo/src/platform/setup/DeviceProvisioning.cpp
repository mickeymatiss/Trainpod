#include "DeviceProvisioning.h"
#include <nvs.h>
#include <cstring>
namespace {
constexpr const char* Namespace="tp_binding";
constexpr const char* Key="record";
constexpr const char* PendingKey="setup_pending";
constexpr const char* StatusUUID="7A1C0004-8F4A-4D2B-9A57-1C2D3E4F5001";
constexpr const char* CommandUUID="7A1C0005-8F4A-4D2B-9A57-1C2D3E4F5001";
constexpr const char* ResultUUID="7A1C0006-8F4A-4D2B-9A57-1C2D3E4F5001";
bool nonzero(const uint8_t* p,size_t n) { uint8_t v=0;while(n--)v|=*p++;return v!=0; }
bool equal(const uint8_t* a,const uint8_t* b,size_t n) {
  uint8_t difference=0;while(n--)difference|=*a++ ^ *b++;return difference==0;
}
}
DeviceProvisioning& DeviceProvisioning::shared() { static DeviceProvisioning p;return p; }
void DeviceProvisioning::begin() {
  static_assert(sizeof(Record)==52,"Stable binding record");
  queue_=xQueueCreate(8,sizeof(Frame));
  nvs_handle_t h;
  esp_err_t error=nvs_open(Namespace,NVS_READWRITE,&h);
  if(error==ESP_OK) {
    size_t size=sizeof(record_);
    error=nvs_get_blob(h,Key,&record_,&size);
    if(error==ESP_ERR_NVS_NOT_FOUND) { record_=Record{};error=ESP_OK; }
    else if(error==ESP_OK) {
      if(size!=sizeof(record_) || record_.version!=1 || !nonzero(record_.app,16) || !nonzero(record_.key,32)) error=ESP_FAIL;
      else provisioned_=true;
    }
    if(error==ESP_OK && provisioned()) {
      uint8_t pending=0;
      const esp_err_t pendingError=nvs_get_u8(h,PendingKey,&pending);
      if(pendingError==ESP_OK) preferencesPending_=pending!=0;
      else if(pendingError!=ESP_ERR_NVS_NOT_FOUND) error=pendingError;
      // Existing registrations without this key retain their normal lifecycle.
    }
    nvs_close(h);
  }
  storageReady_=error==ESP_OK && queue_;
  if(!storageReady_) Serial.println("[SETUP] Storage unavailable; existing record preserved");
  else if(provisioned()) Serial.println("[SETUP] Device is provisioned");
  else {
    Serial.println("[SETUP] Device is unprovisioned");
    Serial.println("[SETUP] Waiting for setup button");
  }
}
DeviceProvisioning::State DeviceProvisioning::state() const {
  if(!storageReady_) return StorageError;
  if(provisioned()) return Provisioned;
  return window_ ? SetupReady : Unprovisioned;
}
void DeviceProvisioning::buttonPressed() {
  if(provisioned() || !storageReady_) return;
  window_=true; // Physical confirmation lasts until claim or restart.
  Serial.println("[SETUP] Setup window opened");Serial.println("[SETUP] setupReady=true");
}
bool DeviceProvisioning::persist(const Record& record,bool preferencesPending) {
  nvs_handle_t h;
  if(nvs_open(Namespace,NVS_READWRITE,&h)!=ESP_OK) return false;
  esp_err_t e=nvs_set_blob(h,Key,&record,sizeof(record));
  if(e==ESP_OK)e=nvs_set_u8(h,PendingKey,preferencesPending ? 1 : 0);
  if(e==ESP_OK)e=nvs_commit(h);
  nvs_close(h);return e==ESP_OK;
}
bool DeviceProvisioning::completeSetup() {
  if(!provisioned() || !storageReady_)return false;
  if(!preferencesPending_)return true; // Lost ACK retries are idempotent.
  if(!persist(record_,false))return false;
  preferencesPending_=false;
  Serial.println("[SETUP] Preferences confirmed; normal BLE lifecycle restored");
  return true;
}
bool DeviceProvisioning::clearProvisioning() {
  nvs_handle_t h;
  if(nvs_open(Namespace,NVS_READWRITE,&h)!=ESP_OK)return false;
  esp_err_t e=nvs_erase_key(h,Key);
  if(e==ESP_ERR_NVS_NOT_FOUND)e=ESP_OK;
  if(e==ESP_OK) { e=nvs_erase_key(h,PendingKey);if(e==ESP_ERR_NVS_NOT_FOUND)e=ESP_OK; }
  if(e==ESP_OK)e=nvs_commit(h);
  nvs_close(h);
  if(e!=ESP_OK)return false;
  record_=Record{};provisioned_=false;window_=false;preferencesPending_=false;storageReady_=queue_!=nullptr;
  ++epoch_;next_=0;
  Serial.println("[SETUP] Provisioning cleared; permanent identity preserved");return true;
}
bool DeviceProvisioning::attach(NimBLEService* service) {
  status_=service->createCharacteristic(StatusUUID,NIMBLE_PROPERTY::READ,2);
  command_=service->createCharacteristic(CommandUUID,NIMBLE_PROPERTY::WRITE,20);
  result_=service->createCharacteristic(ResultUUID,NIMBLE_PROPERTY::READ|NIMBLE_PROPERTY::NOTIFY,6);
  if(!status_ || !command_ || !result_)return false;
  status_->setCallbacks(&callbacks_);command_->setCallbacks(&callbacks_);
  uint8_t empty[6]={1,0,0,0,0,0};result_->setValue(empty,6);
  return true;
}
void DeviceProvisioning::detached() { disconnected();status_=command_=result_=nullptr; }
void DeviceProvisioning::connected(uint16_t peer) { ++epoch_;peer_=peer; }
void DeviceProvisioning::disconnected() { peer_=BLE_HS_CONN_HANDLE_NONE;++epoch_; }
void DeviceProvisioning::Callbacks::onRead(NimBLECharacteristic* c,NimBLEConnInfo&) {
  auto& p=DeviceProvisioning::shared();uint8_t data[]={1,uint8_t(p.state())};c->setValue(data,2);
}
void DeviceProvisioning::Callbacks::onWrite(NimBLECharacteristic* c,NimBLEConnInfo& info) {
  auto value=c->getValue();DeviceProvisioning::shared().receive(value.data(),value.size(),info.getConnHandle());
}
void DeviceProvisioning::receive(const uint8_t* data,size_t size,uint16_t peer) {
  if(!queue_ || peer!=peer_.load() || size<6 || size>20)return;
  Frame f{};f.epoch=epoch_;f.size=size;memcpy(f.data,data,size);
  xQueueSend(queue_,&f,0); // A full queue causes a retry, never partial persistence.
}
void DeviceProvisioning::respond(uint32_t token,uint8_t code) {
  if(!result_)return;
  uint8_t data[6]={1,0,0,0,0,code};
  for(int i=0;i<4;++i)data[i+1]=token>>(8*i);
  result_->setValue(data,6);
  if(peer_!=BLE_HS_CONN_HANDLE_NONE)result_->notify(data,6,peer_);
}
void DeviceProvisioning::update() {
  if(!queue_)return;
  Frame f;
  for(int count=0;count<8 && xQueueReceive(queue_,&f,0)==pdTRUE;++count) {
    if(f.epoch!=epoch_.load() || peer_==BLE_HS_CONN_HANDLE_NONE)continue;
    uint32_t token=0;for(int i=0;i<4;++i)token|=uint32_t(f.data[i+1])<<(8*i);
    const uint8_t op=f.data[0],index=f.data[5];
    if((op!=1 && op!=2 && op!=3) || index>3 || !token || f.size!=(index==3 ? 12 : 20)) { next_=0;respond(token,6);continue; }
    if(index==0) { next_=0;token_=token;operation_=op;assemblyEpoch_=f.epoch;assemblyStarted_=millis(); }
    if(index!=next_ || token!=token_ || op!=operation_ || f.epoch!=assemblyEpoch_ || uint32_t(millis()-assemblyStarted_)>10000) { next_=0;respond(token,6);continue; }
    memcpy(credentials_+14*index,f.data+6,f.size-6);
    if(++next_!=4)continue;
    next_=0;
    uint8_t code=6;
    if(!storageReady_)code=5;
    else if(!nonzero(credentials_,16) || !nonzero(credentials_+16,32))code=6;
    else if(op==3) {
      // Explicit developer reset: only the currently bound installation/key may erase.
      // Persistence must succeed before returning success; permanent identity is untouched.
      const bool owner=provisioned() && equal(record_.app,credentials_,16) && equal(record_.key,credentials_+16,32);
      code=!owner ? 4 : clearProvisioning() ? 1 : 5;
      Serial.println(code==1 ? "[SETUP] Registration reset confirmed" : "[SETUP] Registration reset rejected");
    } else if(op==2) {
      code=provisioned() && equal(record_.app,credentials_,16) && equal(record_.key,credentials_+16,32) ? 1 : 4;
      Serial.println(code==1 ? "[SETUP] Binding recovery accepted" : "[SETUP] Binding recovery rejected");
    } else if(provisioned()) { code=3;Serial.println("[SETUP] Claim rejected: device already provisioned"); }
    else if(state()!=SetupReady) { code=2;Serial.println("[SETUP] Claim rejected: setup window not active"); }
    else {
      Serial.println("[SETUP] Claim request received");
      Record candidate;memcpy(candidate.app,credentials_,16);memcpy(candidate.key,credentials_+16,32);
      if(persist(candidate,true)) {
        record_=candidate;preferencesPending_=true;provisioned_=true;window_=false;code=1;
        Serial.println("[SETUP] Binding persisted");Serial.println("[SETUP] Provisioning complete");
      } else { storageReady_=false;code=5;Serial.println("[SETUP] Storage error; retry after reboot"); }
      memset(&candidate,0,sizeof(candidate));
    }
    memset(credentials_,0,sizeof(credentials_));respond(token,code);
  }
}

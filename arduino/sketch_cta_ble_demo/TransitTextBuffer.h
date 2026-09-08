#pragma once
#include <stdint.h>
#include <stddef.h>
#include <string.h>

// Compatibility with the existing unframed iOS transit sender.
// Caller serializes access. Text messages must be separated by 250 ms idle.
class TransitTextBuffer {
public:
  static constexpr size_t CAPACITY=2048;
  void reset() { length_=0; overflow_=false; }
  void accept(const uint8_t* bytes,size_t size,uint64_t now) {
    if(!size) return;
    last_=now;
    if(size>CAPACITY-length_ || memchr(bytes,0,size)) overflow_=true;
    if(!overflow_) { memcpy(data_+length_,bytes,size); length_+=size; }
  }
  bool ready(uint64_t now) const {
    return (length_ || overflow_) && now-last_>=250000;
  }
  bool invalid() const { return overflow_; }
  const char* text() { data_[length_]=0; return data_; }
private:
  char data_[CAPACITY+1]{};
  size_t length_=0;
  uint64_t last_=0;
  bool overflow_=false;
};

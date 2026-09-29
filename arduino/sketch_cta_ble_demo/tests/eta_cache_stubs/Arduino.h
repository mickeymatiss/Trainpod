#pragma once
#include <cstddef>
#include <cstdint>
inline unsigned glyphReads=0;
inline uint8_t pgm_read_byte(const uint8_t* p) { ++glyphReads; return *p; }
class Print {
public:
  virtual ~Print()=default;
  virtual size_t write(uint8_t)=0;
  virtual size_t write(const uint8_t*,size_t)=0;
  template<class... T> void printf(const char*,T...) {}
  void println(const char*) {}
};

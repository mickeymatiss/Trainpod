#pragma once
#include <Arduino.h>

// App serial output only; diagnostic records are retained independently.
class SerialLog : public Print {
public:
  enum class Level { Debug, Info, Warn };
  explicit SerialLog(Level level) : level_(level) {}
  using Print::write;
  size_t write(uint8_t byte) override { return write(&byte,1); }
  size_t write(const uint8_t* data,size_t size) override;
  static bool beginDeferred();
  static void deferCurrentTask();
  static void drainDeferred(); // App loop only, bounded work.
  static bool command(const char* line);
private:
  Level level_;
  bool lineStart_=true;
};
extern SerialLog DebugLog,InfoLog,WarnLog;

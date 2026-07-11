// date_fuzzer.cc — libFuzzer/standalone harness for HowardHinnant/date.
//
// Fuzzed surface: the header-only date::parse() / date::from_stream() parser, which is the
// untrusted-input entry point of the library (it turns an attacker-controlled FORMAT string +
// DATA string into calendar/time values via a std::istream). This is the same surface the
// OSS-Fuzz `date` project fuzzes; it is fully self-contained in include/date/date.h and needs
// NO IANA timezone database (so it runs offline and deterministically).
//
// Input layout (deterministic split, no external FuzzedDataProvider dependency):
//   byte 0           : format length selector L (we cap it at the input size)
//   bytes [1 .. 1+F) : the strftime-style FORMAT string  (F = min(L, remaining))
//   bytes [1+F ..  ) : the DATA string fed to the parser
// Both halves are attacker-controlled, exercising the format directive scanner and the field
// readers (read_signed/read_unsigned/scan_keyword, %F/%T/%a/%b/%z/%Z handling, ...).

#include "date.h"

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <sstream>
#include <string>

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
  if (size == 0) {
    return 0;
  }

  // Split: first byte picks how much of the remainder is the format string.
  size_t remaining = size - 1;
  size_t fmt_len = (remaining == 0) ? 0 : (static_cast<size_t>(data[0]) % (remaining + 1));

  std::string fmt(reinterpret_cast<const char*>(data + 1), fmt_len);
  std::string payload(reinterpret_cast<const char*>(data + 1 + fmt_len),
                      remaining - fmt_len);

  using namespace date;

  // Parse into a handful of representative Parsable types to widen the directive coverage.
  // Each parse is independent and errors are swallowed (the stream just goes into fail state);
  // we only care about crashes / sanitizer reports inside the parser itself.
  {
    std::istringstream in(payload);
    sys_seconds tp;
    std::string abbrev;
    std::chrono::minutes offset{};
    in >> date::parse(fmt, tp, abbrev, offset);
  }
  {
    std::istringstream in(payload);
    sys_days dp;
    in >> date::parse(fmt, dp);
  }
  {
    std::istringstream in(payload);
    year_month_day ymd{};
    in >> date::parse(fmt, ymd);
  }
  {
    std::istringstream in(payload);
    weekday wd{0u};
    in >> date::parse(fmt, wd);
  }

  return 0;
}

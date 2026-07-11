// standalone_main.cc — run-once driver for the date fuzz harness (no libFuzzer runtime).
// Reads a single input file and feeds its bytes to LLVMFuzzerTestOneInput, so a Mayhem/libFuzzer
// crashing input can be replayed under a plain debugger. Mirrors $STANDALONE_FUZZ_MAIN.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size);

int main(int argc, char** argv) {
  if (argc != 2) {
    std::fprintf(stderr, "usage: %s <input-file>\n", argv[0]);
    return 1;
  }
  std::FILE* f = std::fopen(argv[1], "rb");
  if (!f) {
    std::fprintf(stderr, "failed to open %s\n", argv[1]);
    return 2;
  }
  std::fseek(f, 0, SEEK_END);
  long n = std::ftell(f);
  std::fseek(f, 0, SEEK_SET);
  if (n < 0) {
    std::fclose(f);
    return 3;
  }
  std::vector<uint8_t> buf(static_cast<size_t>(n));
  size_t got = (n > 0) ? std::fread(buf.data(), 1, static_cast<size_t>(n), f) : 0;
  std::fclose(f);
  LLVMFuzzerTestOneInput(buf.data(), got);
  return 0;
}

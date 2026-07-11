// date_behavior_checker.cc — behavioral oracle for mayhem/test.sh
//
// Exercises date::parse() + date::format() with hard-coded known-answer
// inputs and PRINTS each result to stdout so the shell test can grep for
// expected strings.  Intentionally does NOT use assert() — when the program
// is neutered to exit(0) nothing is printed, and the test.sh grep fails,
// making the oracle reward-hack-proof.
//
// Compiled by mayhem/build.sh with NORMAL (non-sanitizer) flags so it is an
// honest functional checker separate from the fuzz/sanitizer pipeline.

#include "date.h"

#include <cstdlib>
#include <iostream>
#include <sstream>
#include <string>

// Returns the formatted result of parsing `input` with `in_fmt` into type T,
// then formatting with `out_fmt`.  Returns "FAIL" if the parse fails.
template <class T>
static std::string round_trip(const std::string& in_fmt,
                              const std::string& input,
                              const std::string& out_fmt) {
    using namespace date;
    std::istringstream in{input};
    T t{};
    in >> parse(in_fmt, t);
    if (in.fail()) return "FAIL";
    return date::format(out_fmt, t);
}

int main() {
    using namespace date;
    bool ok = true;

    // Each test: label, computed, expected
    struct Case { const char* label; std::string got; std::string want; };

    Case cases[] = {
        { "year_round_trip",
          round_trip<year>("%Y", "2017", "%Y"),
          "2017" },
        { "month_round_trip",
          round_trip<month>("%m", "3", "%m"),
          "03" },
        { "day_round_trip",
          round_trip<day>("%d", "25", "%d"),
          "25" },
        { "year_month_round_trip",
          round_trip<year_month>("%Y-%m", "2017-03", "%Y-%m"),
          "2017-03" },
        { "month_day_round_trip",
          round_trip<month_day>("%m/%d", "3/25", "%m/%d"),
          "03/25" },
        // format a hard-coded date: 2016-12-11 (from the parse.pass.cpp suite)
        { "ymd_format_iso",
          date::format("%F", date::year{2016}/date::December/date::day{11}),
          "2016-12-11" },
        // a sys_days round-trip through parse
        { "sys_days_round_trip",
          round_trip<sys_days>("%F", "2021-07-04", "%F"),
          "2021-07-04" },
        // weekday parse: Wednesday = 3
        { "weekday_parse",
          round_trip<weekday>("%w", "3", "%w"),
          "3" },
    };

    for (auto& c : cases) {
        std::cout << c.label << "=" << c.got << "\n";
        if (c.got != c.want) {
            std::cerr << "MISMATCH " << c.label
                      << ": got='" << c.got
                      << "' want='" << c.want << "'\n";
            ok = false;
        }
    }

    return ok ? 0 : 1;
}

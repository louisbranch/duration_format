//// Tests ported from Go's src/time/time_test.go (parseDurationTests
//// and parseDurationErrorTests).
////
//// Tests using raw invalid-UTF-8 byte sequences (e.g. "\xffff") are
//// omitted — Gleam strings cannot represent them. The U+FFFD
//// replacement-character cases from the Go table are kept.

import duration_format/go
import gleam/list
import gleam/time/duration

const second = 1_000_000_000

const millisecond = 1_000_000

const microsecond = 1000

const minute = 60_000_000_000

const hour = 3_600_000_000_000

fn ok_cases() -> List(#(String, Int)) {
  [
    // simple
    #("0", 0),
    #("5s", 5 * second),
    #("30s", 30 * second),
    #("1478s", 1478 * second),
    // sign
    #("-5s", -5 * second),
    #("+5s", 5 * second),
    #("-0", 0),
    #("+0", 0),
    // decimal
    #("5.0s", 5 * second),
    #("5.6s", 5 * second + 600 * millisecond),
    #("5.s", 5 * second),
    #(".5s", 500 * millisecond),
    #("1.0s", 1 * second),
    #("1.00s", 1 * second),
    #("1.004s", 1 * second + 4 * millisecond),
    #("1.0040s", 1 * second + 4 * millisecond),
    #("100.00100s", 100 * second + 1 * millisecond),
    // different units
    #("10ns", 10),
    #("11us", 11 * microsecond),
    #("12µs", 12 * microsecond),
    #("12μs", 12 * microsecond),
    #("13ms", 13 * millisecond),
    #("14s", 14 * second),
    #("15m", 15 * minute),
    #("16h", 16 * hour),
    // composite
    #("3h30m", 3 * hour + 30 * minute),
    #("10.5s4m", 4 * minute + 10 * second + 500 * millisecond),
    #("-2m3.4s", -{ 2 * minute + 3 * second + 400 * millisecond }),
    #(
      "1h2m3s4ms5us6ns",
      1 * hour + 2 * minute + 3 * second + 4 * millisecond + 5 * microsecond + 6,
    ),
    #("39h9m14.425s", 39 * hour + 9 * minute + 14 * second + 425 * millisecond),
    // large value
    #("52763797000ns", 52_763_797_000),
    // more than 9 digits after decimal point
    #("0.3333333333333333333h", 20 * minute),
    // 1<<53+1 — cannot be precisely stored in float64
    #("9007199254740993ns", 9_007_199_254_740_993),
    // largest int64 nanoseconds
    #("9223372036854775807ns", 9_223_372_036_854_775_807),
    #("9223372036854775.807us", 9_223_372_036_854_775_807),
    #("9223372036s854ms775us807ns", 9_223_372_036_854_775_807),
    // largest negative (min int64)
    #("-9223372036854775808ns", -9_223_372_036_854_775_808),
    #("-9223372036854775.808us", -9_223_372_036_854_775_808),
    #("-9223372036s854ms775us808ns", -9_223_372_036_854_775_808),
    // largest negative round trip
    #("-2562047h47m16.854775808s", -9_223_372_036_854_775_808),
    // long fractional that gets truncated by overflow handling
    #("0.100000000000000000000h", 6 * minute),
    // first overflow check in leading_fraction
    #("0.830103483285477580700h", 49 * minute + 48 * second + 372_539_827),
  ]
}

/// Ported from Go's TestDurationString.
fn to_string_cases() -> List(#(Int, String)) {
  [
    #(0, "0s"),
    #(1, "1ns"),
    #(1100, "1.1µs"),
    #(2200 * microsecond, "2.2ms"),
    #(3300 * millisecond, "3.3s"),
    #(4 * minute + 5 * second, "4m5s"),
    #(4 * minute + 5001 * millisecond, "4m5.001s"),
    #(5 * hour + 6 * minute + 7001 * millisecond, "5h6m7.001s"),
    #(8 * minute + 1, "8m0.000000001s"),
    #(9_223_372_036_854_775_807, "2562047h47m16.854775807s"),
    #(-9_223_372_036_854_775_808, "-2562047h47m16.854775808s"),
    // additional sub-second coverage
    #(500 * millisecond, "500ms"),
    #(42 * microsecond, "42µs"),
    // negative sub-second
    #(-1, "-1ns"),
    #(-1100, "-1.1µs"),
    // single-unit super-second
    #(1 * hour, "1h0m0s"),
    #(90 * minute, "1h30m0s"),
  ]
}

fn error_cases() -> List(String) {
  [
    "", "3", "-", "s", ".", "-.", ".s", "+.s", "1d",
    // U+FFFD only (raw \xff byte cases omitted)
    "\u{FFFD}", "\u{FFFD} hello \u{FFFD} world",
    // overflow
    "9223372036854775810ns", "9223372036854775808ns", "-9223372036854775809ns",
    "9223372036854776us", "3000000h", "9223372036854775.808us",
    "9223372036854ms775us808ns",
  ]
}

pub fn parse_ok_cases_test() {
  let failures =
    list.filter_map(ok_cases(), fn(case_) {
      let #(input, expected_ns) = case_
      let expected = duration.nanoseconds(expected_ns)
      case go.parse(input) {
        Ok(actual) if actual == expected -> Error(Nil)
        other -> Ok(#(input, expected_ns, other))
      }
    })
  assert failures == []
}

pub fn parse_error_cases_test() {
  let failures =
    list.filter_map(error_cases(), fn(input) {
      case go.parse(input) {
        Error(_) -> Error(Nil)
        Ok(d) -> Ok(#(input, d))
      }
    })
  assert failures == []
}

pub fn to_string_cases_test() {
  let failures =
    list.filter_map(to_string_cases(), fn(case_) {
      let #(nanos, expected) = case_
      let actual = go.to_string(duration.nanoseconds(nanos))
      case actual == expected {
        True -> Error(Nil)
        False -> Ok(#(nanos, expected, actual))
      }
    })
  assert failures == []
}

/// Every ok-case input must parse to a duration that, when formatted via
/// to_string, parses back to the same duration.
pub fn round_trip_test() {
  let failures =
    list.filter_map(ok_cases(), fn(case_) {
      let #(input, _) = case_
      case go.parse(input) {
        Ok(d1) -> {
          let s = go.to_string(d1)
          case go.parse(s) {
            Ok(d2) if d1 == d2 -> Error(Nil)
            other -> Ok(#(input, s, other))
          }
        }
        Error(e) -> Ok(#(input, "parse failed", Error(e)))
      }
    })
  assert failures == []
}

//// Parse and format durations using Go's `time.ParseDuration` grammar.
////
//// The same format is also used by Prometheus, Kubernetes, HashiCorp tools
//// (Terraform, Consul, Nomad), and InfluxDB — there is no formal
//// specification beyond [Go's docs](https://pkg.go.dev/time#ParseDuration).
////
//// ## Grammar
////
//// ```text
//// duration  = [ sign ] component { component } | [ sign ] "0"
//// sign      = "+" | "-"
//// component = number unit
//// number    = digits [ "." digits ] | "." digits
//// unit      = "ns" | "us" | "µs" | "μs" | "ms" | "s" | "m" | "h"
//// ```
////
//// `µs` is U+00B5 (micro sign — what Go emits); `μs` is U+03BC (Greek
//// small mu) and is accepted on input but never produced.
////
//// ## Examples
////
//// ```gleam
//// go.parse("1h30m")
//// // -> Ok(duration.nanoseconds(5_400_000_000_000))
////
//// go.parse("-2m3.4s")
//// // -> Ok(duration.nanoseconds(-123_400_000_000))
////
//// go.parse("1d")
//// // -> Error(UnknownUnit("d"))
////
//// go.to_string(duration.nanoseconds(5_400_000_000_000))
//// // -> "1h30m0s"
//// ```

import gleam/bool
import gleam/float
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import gleam/time/duration.{type Duration}

/// Reasons a duration string can fail to parse.
pub type Error {
  /// The input was empty, contained only a sign, or otherwise had no
  /// recognisable component.
  InvalidDuration
  /// A numeric component was followed by no unit (e.g. `"3"`).
  MissingUnit
  /// A numeric component was followed by an unrecognised unit. Carries the
  /// offending unit string (e.g. `"d"` from `"1d"`).
  UnknownUnit(String)
  /// The total magnitude would exceed Go's int64 nanosecond range.
  Overflow
}

// Gleam ints are arbitrary-precision; these bounds exist only to mirror
// Go's int64 semantics so that -2^63 is representable. `unsigned_max` is
// 2^63 (Go's parser accumulates in uint64, so the magnitude reaches this);
// `signed_max` is 2^63 - 1 (the largest positive int64).
const unsigned_max = 9_223_372_036_854_775_808

const signed_max = 9_223_372_036_854_775_807

const nanos_per_us = 1000

const nanos_per_ms = 1_000_000

const nanos_per_second = 1_000_000_000

// Both seconds→minutes and minutes→hours use 60.
const seconds_per_minute = 60

fn unit_to_nanos(u: String) -> Result(Int, Error) {
  case u {
    "ns" -> Ok(1)
    "us" | "µs" | "μs" -> Ok(nanos_per_us)
    "ms" -> Ok(nanos_per_ms)
    "s" -> Ok(nanos_per_second)
    "m" -> Ok(seconds_per_minute * nanos_per_second)
    "h" -> Ok(3600 * nanos_per_second)
    other -> Error(UnknownUnit(other))
  }
}

/// Parse a duration string in Go's `time.ParseDuration` format.
///
/// See the module documentation for the accepted grammar.
pub fn parse(input: String) -> Result(Duration, Error) {
  let #(neg, rest) = strip_sign(string.to_graphemes(input))
  case rest {
    ["0"] -> Ok(duration.nanoseconds(0))
    [] -> Error(InvalidDuration)
    _ -> {
      use total <- result.try(parse_components(rest, 0))
      // A negative magnitude can reach unsigned_max (Go's -2^63 is valid);
      // a positive one may not exceed signed_max (2^63 - 1).
      case neg, total > signed_max {
        True, _ -> Ok(duration.nanoseconds(-total))
        False, True -> Error(Overflow)
        False, False -> Ok(duration.nanoseconds(total))
      }
    }
  }
}

fn strip_sign(g: List(String)) -> #(Bool, List(String)) {
  case g {
    ["-", ..r] -> #(True, r)
    ["+", ..r] -> #(False, r)
    _ -> #(False, g)
  }
}

fn parse_components(g: List(String), acc: Int) -> Result(Int, Error) {
  case g {
    [] -> Ok(acc)
    _ -> {
      use #(nanos, rest) <- result.try(parse_component(g))
      let sum = acc + nanos
      use <- bool.guard(sum > unsigned_max, Error(Overflow))
      parse_components(rest, sum)
    }
  }
}

fn parse_component(g: List(String)) -> Result(#(Int, List(String)), Error) {
  use #(int_part, after_int) <- result.try(leading_int(g, 0))
  let had_int = after_int != g

  let #(frac, scale, after_frac, had_frac) = case after_int {
    [".", ..rest] -> {
      let #(f, sc, r) = leading_fraction(rest, 0, 1.0, False)
      #(f, sc, r, r != rest)
    }
    _ -> #(0, 1.0, after_int, False)
  }

  // A component must carry at least one digit, before or after the point.
  use <- bool.guard(!had_int && !had_frac, Error(InvalidDuration))

  let #(unit_str, after_unit) = take_unit_suffix(after_frac)
  use per_unit <- result.try(case unit_str {
    "" -> Error(MissingUnit)
    u -> unit_to_nanos(u)
  })

  use v_int <- result.try(checked_mul(int_part, per_unit))
  let v_frac = case frac {
    0 -> 0
    _ ->
      float.truncate(int.to_float(frac) *. { int.to_float(per_unit) /. scale })
  }
  let v = v_int + v_frac

  use <- bool.guard(v > unsigned_max, Error(Overflow))
  Ok(#(v, after_unit))
}

fn leading_int(
  g: List(String),
  acc: Int,
) -> Result(#(Int, List(String)), Error) {
  case g {
    [c, ..rest] ->
      case int.parse(c) {
        Error(_) -> Ok(#(acc, g))
        Ok(d) ->
          case acc * 10 + d > unsigned_max {
            True -> Error(Overflow)
            False -> leading_int(rest, acc * 10 + d)
          }
      }
    [] -> Ok(#(acc, g))
  }
}

fn leading_fraction(
  g: List(String),
  acc: Int,
  scale: Float,
  overflowed: Bool,
) -> #(Int, Float, List(String)) {
  case g {
    [c, ..rest] ->
      case int.parse(c) {
        Error(_) -> #(acc, scale, g)
        Ok(d) -> {
          // Once we overflow we keep consuming digits but stop accumulating,
          // mirroring Go. Unlike Go we needn't guard the multiply: Gleam ints
          // are arbitrary-precision, so `y > unsigned_max` catches every case.
          let y = acc * 10 + d
          case overflowed || y > unsigned_max {
            True -> leading_fraction(rest, acc, scale, True)
            False -> leading_fraction(rest, y, scale *. 10.0, False)
          }
        }
      }
    [] -> #(acc, scale, g)
  }
}

fn take_unit_suffix(g: List(String)) -> #(String, List(String)) {
  // The unit runs until the next digit or decimal point (the start of the
  // following component, e.g. the "3" in "1h3m").
  let #(unit, rest) =
    list.split_while(g, fn(c) { c != "." && result.is_error(int.parse(c)) })
  #(string.concat(unit), rest)
}

fn checked_mul(a: Int, b: Int) -> Result(Int, Error) {
  case b == 0 || a <= unsigned_max / b {
    True -> Ok(a * b)
    False -> Error(Overflow)
  }
}

/// Format a duration using Go's `Duration.String()` rules.
///
/// Zero formats as `"0s"`. Sub-second magnitudes use the largest unit that
/// keeps a non-zero leading digit (`ns`, `µs`, `ms`). One-second-and-up emits
/// `<h>h<m>m<s>s` with trailing zero units omitted and a fractional seconds
/// component when needed.
pub fn to_string(d: Duration) -> String {
  format_duration(d, trim: False)
}

/// Like `to_string`, but with trailing zero components dropped.
///
/// `to_string` always emits a full `<h>h<m>m<s>s` tail for one-second-and-up
/// durations, so an exact hour formats as `"1h0m0s"`. This variant drops
/// trailing zero units, yielding `"1h"` or `"1h30m"` instead. Intermediate
/// zeros are preserved — `"1h0m30s"` keeps its `0m` — and a zero seconds
/// component is kept when it carries a fraction (e.g. `"8m0.000000001s"`).
/// Zero still formats as `"0s"`, and sub-second magnitudes are unchanged. The
/// result always parses back to the same duration.
pub fn to_string_trimmed(d: Duration) -> String {
  format_duration(d, trim: True)
}

fn format_duration(d: Duration, trim trim: Bool) -> String {
  let #(s, ns) = duration.to_seconds_and_nanoseconds(d)
  case s * nanos_per_second + ns {
    0 -> "0s"
    n if n < 0 -> "-" <> format_magnitude(-n, trim)
    n -> format_magnitude(n, trim)
  }
}

fn format_magnitude(u: Int, trim: Bool) -> String {
  case u < nanos_per_second {
    True -> format_subsecond(u)
    False -> format_supersecond(u, trim)
  }
}

fn format_subsecond(u: Int) -> String {
  case u {
    _ if u < nanos_per_us -> int.to_string(u) <> "ns"
    _ if u < nanos_per_ms -> format_with_fraction(u, nanos_per_us, 3) <> "µs"
    _ -> format_with_fraction(u, nanos_per_ms, 6) <> "ms"
  }
}

fn format_supersecond(u: Int, trim: Bool) -> String {
  let total_seconds = u / nanos_per_second
  let frac_nanos = u % nanos_per_second
  let secs = total_seconds % seconds_per_minute
  let total_minutes = total_seconds / seconds_per_minute
  let mins = total_minutes % seconds_per_minute
  let hours = total_minutes / seconds_per_minute

  let show_hours = hours > 0
  // When trimming we drop only trailing zero components; a zero seconds
  // value is still kept when it carries a fraction (e.g. "8m0.000000001s").
  let show_secs = case trim {
    True -> secs > 0 || frac_nanos > 0
    False -> True
  }
  // Minutes are emitted when non-zero, or — to preserve intermediate zeros —
  // whenever they sit between a shown hour and a shown second.
  let show_mins = case trim {
    True -> mins > 0 || { show_hours && show_secs }
    False -> hours > 0 || mins > 0
  }

  let seconds_str = case show_secs {
    True -> int.to_string(secs) <> format_fraction(frac_nanos, 9) <> "s"
    False -> ""
  }
  let with_mins = case show_mins {
    True -> int.to_string(mins) <> "m" <> seconds_str
    False -> seconds_str
  }
  case show_hours {
    True -> int.to_string(hours) <> "h" <> with_mins
    False -> with_mins
  }
}

fn format_with_fraction(u: Int, divisor: Int, digits: Int) -> String {
  let whole = u / divisor
  let frac = u % divisor
  int.to_string(whole) <> format_fraction(frac, digits)
}

fn format_fraction(frac: Int, digits: Int) -> String {
  case frac {
    0 -> ""
    _ -> {
      let raw = int.to_string(frac)
      let padding = digits - string.length(raw)
      let padded = string.repeat("0", padding) <> raw
      "." <> trim_trailing_zeros(padded)
    }
  }
}

fn trim_trailing_zeros(s: String) -> String {
  s
  |> string.to_graphemes
  |> list.reverse
  |> list.drop_while(fn(c) { c == "0" })
  |> list.reverse
  |> string.join("")
}

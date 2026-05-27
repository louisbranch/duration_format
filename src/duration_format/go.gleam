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
      case neg {
        True -> Ok(duration.nanoseconds(-total))
        False ->
          case total > signed_max {
            True -> Error(Overflow)
            False -> Ok(duration.nanoseconds(total))
          }
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
      case sum > unsigned_max {
        True -> Error(Overflow)
        False -> parse_components(rest, sum)
      }
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

  case had_int || had_frac {
    False -> Error(InvalidDuration)
    True -> {
      let #(unit_str, after_unit) = take_unit_suffix(after_frac, "")
      use per_unit <- result.try(case unit_str {
        "" -> Error(MissingUnit)
        u -> unit_to_nanos(u)
      })

      use v_int <- result.try(checked_mul(int_part, per_unit))
      let v_frac = case frac {
        0 -> 0
        _ ->
          float.truncate(
            int.to_float(frac) *. { int.to_float(per_unit) /. scale },
          )
      }
      let v = v_int + v_frac
      case v > unsigned_max {
        True -> Error(Overflow)
        False -> Ok(#(v, after_unit))
      }
    }
  }
}

fn leading_int(
  g: List(String),
  acc: Int,
) -> Result(#(Int, List(String)), Error) {
  case g {
    [c, ..rest] ->
      case int.parse(c) {
        Ok(d) ->
          case acc > unsigned_max / 10 {
            True -> Error(Overflow)
            False -> {
              let y = acc * 10 + d
              case y > unsigned_max {
                True -> Error(Overflow)
                False -> leading_int(rest, y)
              }
            }
          }
        Error(_) -> Ok(#(acc, g))
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
        Ok(d) ->
          case overflowed {
            True -> leading_fraction(rest, acc, scale, True)
            False ->
              case acc > signed_max / 10 {
                True -> leading_fraction(rest, acc, scale, True)
                False -> {
                  let y = acc * 10 + d
                  case y > unsigned_max {
                    True -> leading_fraction(rest, acc, scale, True)
                    False -> leading_fraction(rest, y, scale *. 10.0, False)
                  }
                }
              }
          }
        Error(_) -> #(acc, scale, g)
      }
    [] -> #(acc, scale, g)
  }
}

fn take_unit_suffix(g: List(String), acc: String) -> #(String, List(String)) {
  case g {
    [c, ..rest] ->
      case int.parse(c), c {
        Ok(_), _ -> #(acc, g)
        _, "." -> #(acc, g)
        _, _ -> take_unit_suffix(rest, acc <> c)
      }
    [] -> #(acc, g)
  }
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
  let #(s, ns) = duration.to_seconds_and_nanoseconds(d)
  let total = s * nanos_per_second + ns
  case total {
    0 -> "0s"
    n if n < 0 -> "-" <> format_magnitude(-n)
    n -> format_magnitude(n)
  }
}

fn format_magnitude(u: Int) -> String {
  case u < nanos_per_second {
    True -> format_subsecond(u)
    False -> format_supersecond(u)
  }
}

fn format_subsecond(u: Int) -> String {
  case u {
    _ if u < nanos_per_us -> int.to_string(u) <> "ns"
    _ if u < nanos_per_ms -> format_with_fraction(u, nanos_per_us, 3) <> "µs"
    _ -> format_with_fraction(u, nanos_per_ms, 6) <> "ms"
  }
}

fn format_supersecond(u: Int) -> String {
  let total_seconds = u / nanos_per_second
  let frac_nanos = u % nanos_per_second
  let secs = total_seconds % seconds_per_minute
  let total_minutes = total_seconds / seconds_per_minute
  let mins = total_minutes % seconds_per_minute
  let hours = total_minutes / seconds_per_minute

  let seconds_str = int.to_string(secs) <> format_fraction(frac_nanos, 9) <> "s"
  let with_mins = case hours > 0 || mins > 0 {
    True -> int.to_string(mins) <> "m" <> seconds_str
    False -> seconds_str
  }
  case hours > 0 {
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

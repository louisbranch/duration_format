# duration_format

[![Package Version](https://img.shields.io/hexpm/v/duration_format)](https://hex.pm/packages/duration_format)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/duration_format/)

Parse and format `gleam/time/duration.Duration` values in established string
formats. Currently supports Go's `time.ParseDuration` grammar — the same
format used by Prometheus, Kubernetes, HashiCorp tools (Terraform, Consul,
Nomad), and InfluxDB.

```sh
gleam add duration_format
```

```gleam
import duration_format/go
import gleam/io

pub fn main() -> Nil {
  let assert Ok(d) = go.parse("1h30m")
  io.println(go.to_string(d))
  // -> "1h30m0s"

  case go.parse("1d") {
    Ok(_) -> Nil
    Error(go.UnknownUnit(u)) -> io.println("unsupported unit: " <> u)
    Error(_) -> Nil
  }
}
```

## Supported formats

| Module | Format |
| --- | --- |
| `duration_format/go` | Go's `time.ParseDuration` grammar (`"1h30m"`, `"-2m3.4s"`, `"500ms"`, …) |

Each format module exposes its own `parse`, `to_string`, and `Error` type.

## Other time libraries

`duration_format` only handles duration string formats. For broader time work,
consider:

- [`gleam_time`](https://hexdocs.pm/gleam_time/) — the standard library's core types for timestamps and durations.
- [`birl`](https://hexdocs.pm/birl/) — date/time handling with its own whitespace-based duration grammar (`"1 hour + 30 minutes"`).
- [`gtempo`](https://hexdocs.pm/gtempo/) — a datetime-centric, mockable time library with parsing and formatting.
- [`gtz`](https://hexdocs.pm/gtz/) — a timezone data provider that pairs with `gtempo`.
- [`rada`](https://hexdocs.pm/rada/) — a Date type for calendar dates without times or zones, ported from Elm's `justinmimbs/date`.
- [`timeago`](https://hex.pm/packages/timeago) — formats timestamps as human-readable relative strings like `"5 minutes ago"`.

## Development

```sh
gleam test                       # run tests
gleam format --check src test    # check formatting
```

Further documentation is at <https://hexdocs.pm/duration_format>.

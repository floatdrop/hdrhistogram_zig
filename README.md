# hdrhistogram_zig [![CI](https://github.com/floatdrop/hdrhistogram_zig/actions/workflows/ci.yaml/badge.svg)](https://github.com/floatdrop/hdrhistogram_zig/actions/workflows/ci.yaml)

[High Dynamic Range Histogram](https://github.com/HdrHistogram/HdrHistogram) implementation in Zig.

> A Histogram that supports recording and analyzing sampled data value counts
> across a configurable integer value range with configurable value precision
> within the range. Value precision is expressed as the number of significant
> digits in the value recording, and provides control over value quantization
> behavior across the value range and the subsequent value resolution at any
> given level.

This implementation provides static struct type, which size is computed in
`comptime`.

```zig
const HdrHistogram = @import("hdrhistogram").HdrHistogram;

pub fn main() void {
    std.debug.print("Size of plain array  : {d:12} bytes\n", .{@sizeOf([10_000_000_000]u64)});
    std.debug.print("Size of HdrHistogram : {d:12} bytes\n", .
      {@sizeOf(HdrHistogram(1, 10_000_000_000, .three_digits))
    });

    /// Size of plain array  : 80000000000 bytes
    /// Size of HdrHistogram :      204808 bytes
}
```

Many methods are absent yet, but most common are implemented.

## Statistics

- `total_count`
- `min()`
- `max()`
- `mean()`
- `stdDev()`
- `percentiles(&.{...})`

## Iterating buckets

To iterate over all counts with their lowers and highest equivalent values:

```zig
var iter = h.iterator();

while (iter.next()) |bucket| {
  std.debug.print("count={d} in {d}..{d} range\n", .{
    bucket.count,
    bucket.lowest_equivalent_value,
    bucket.highest_equivalent_value,
  });
}
```

You can use `PercentileIterator` wrapper to iterate over percentiles:

```zig
var iter = h.iterator().percentile();

while (iter.next()) |p| {
    std.debug.print("value={d} in {d:.2}%\n", .{p.value, p.percentile});
}
```

## Merging histograms

Use `merge` method to add data from one histogram to another.

```zig
const other1: HdrHistogram(1, 10_000_000_000, .three_digits);
const other2: HdrHistogram(1, 10_000_000_000, .three_digits);
var sum: HdrHistogram(1, 10_000_000_000, .three_digits) = .init();

sum.merge(other1);
sum.merge(other2);
```

## Benchmarks

Inserting 10_000_000 records in a for-loop:

```
Benchmark 1 (460 runs): ./bench/c-recording/zig-out/bin/c_recording
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          21.7ms ± 7.61ms    19.9ms …  183ms          5 ( 1%)        0%
  peak_rss           2.05MB ± 61.4KB    1.77MB … 2.23MB        174 (38%)        0%
  cpu_cycles         94.5M  ± 37.0M     91.8M  …  885M          28 ( 6%)        0%
  instructions        520M  ± 8.56       520M  …  520M          10 ( 2%)        0%
  cache_references   59.5K  ±  821K     16.9K  … 17.6M          58 (13%)        0%
  cache_misses       5.18K  ±  279      4.70K  … 6.41K          65 (14%)        0%
  branch_misses      3.62K  ± 30.7      3.57K  … 4.04K          11 ( 2%)        0%
Benchmark 2 (1487 runs): ./bench/zig-recording/zig-out/bin/zig_recording
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          6.69ms ±  460us    5.87ms … 9.33ms         63 ( 4%)        ⚡- 69.2% ±  1.8%
  peak_rss            815KB ± 8.06KB     659KB …  815KB          4 ( 0%)        ⚡- 60.2% ±  0.2%
  cpu_cycles         26.6M  ±  127K     26.5M  … 27.6M         128 ( 9%)        ⚡- 71.9% ±  2.0%
  instructions        114M  ± 1.65       114M  …  114M          18 ( 1%)        ⚡- 78.1% ±  0.0%
  cache_references   6.13K  ±  585      5.33K  … 19.0K          41 ( 3%)        ⚡- 89.7% ± 70.2%
  cache_misses        156   ±  104        50   … 1.85K          87 ( 6%)        ⚡- 97.0% ±  0.3%
  branch_misses       122   ± 6.67        83   …  146          104 ( 7%)        ⚡- 96.6% ±  0.0%
```

Run `make bench-poop` or `make bench-hyperfine` to start benchmarks.

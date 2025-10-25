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
    ///                            390609x less space
}
```

Many methods are absent yet, but most common are implemented.

## Statistics

- `total_count`
- `min`
- `max`
- `mean`
- `stdDev`
- `percentile`

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

If you have histograms of same type - you can just create histogram with `.counts`
set to be a sum of other histograms `.counts`.

```zig
const other1: HdrHistogram(1, 10_000_000_000, .three_digits);
const other2: HdrHistogram(1, 10_000_000_000, .three_digits);
var sum: HdrHistogram(1, 10_000_000_000, .three_digits) = .{ 
  .counts = other1.counts + other2.counts
}; // Created counts from other histograms
```

Otherwise summing can be done by iterating over buckets and recording
`lowest_equivalent_value` with respective count:

```zig
 // Leaves counts uninitialized
const other: HdrHistogram(1, 10_000_000_000, .three_digits) = .{};

 // Sets .counts to 0
var h: HdrHistogram(1, 10_000_000_000, .three_digits) = .init();

var iter = other.iterator();
while (iter.next()) |bucket| {
    h.recordN(iter.lowest_equivalent_value, iter.count);
}
```

## Benchmarks

```
Benchmark 1 (478 runs): ./bench/c-recording/zig-out/bin/c_recording
  measurement          mean ± σ            min … max           outliers         delta
  wall_time          20.9ms ± 3.17ms    19.7ms … 76.0ms         10 ( 2%)        0%
  peak_rss           1.91MB ± 55.9KB    1.76MB … 2.10MB        175 (37%)        0%
  cpu_cycles         92.3M  ± 14.7M     90.3M  …  360M          34 ( 7%)        0%
  instructions        510M  ± 7.73       510M  …  510M          25 ( 5%)        0%
  cache_references   16.5K  ±  492      14.5K  … 19.2K          16 ( 3%)        0%
  cache_misses       5.07K  ±  294      4.42K  … 6.33K          26 ( 5%)        0%
  branch_misses      3.60K  ± 33.8      3.53K  … 3.82K          21 ( 4%)        0%
Benchmark 2 (10000 runs): ./bench/zig-recording/zig-out/bin/zig_recording
  measurement          mean ± σ            min … max           outliers         delta
  wall_time           157us ± 26.3us     123us …  486us        234 ( 2%)        ⚡- 99.2% ±  0.3%
  peak_rss            806KB ± 10.3KB     598KB …  807KB         44 ( 0%)        ⚡- 57.9% ±  0.1%
  cpu_cycles         2.93K  ±  208      2.51K  … 4.86K         567 ( 6%)        ⚡-100.0% ±  0.3%
  instructions        781   ± 0.19       781   …  783          374 ( 4%)        ⚡-100.0% ±  0.0%
  cache_references    220   ± 24.2       143   …  349          146 ( 1%)        ⚡- 98.7% ±  0.1%
  cache_misses       48.6   ± 19.7         3   …  127           34 ( 0%)        ⚡- 99.0% ±  0.1%
  branch_misses      28.6   ± 7.39        14   …   57          215 ( 2%)        ⚡- 99.2% ±  0.0%
```

Run `make bench-poop` or `make bench-hyperfine` to start benchmarks.

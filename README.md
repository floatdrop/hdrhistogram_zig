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
    std.debug.print("Size of HdrHistogram : {d:12} bytes\n", .{@sizeOf(HdrHistogram(1, 10_000_000_000, .three_digits))});

    /// Size of plain array  : 80000000000 bytes
    /// Size of HdrHistogram :      204856 bytes
    ///                            390518x less space
}
```

Many methods are absent yet, but most common are implemented.

## Statistics

 - `total_count`
 - `min`
 - `max`
 - `mean`
 - `stdDev`
 - `valueAtPercentile`

## Iterating buckets

To iterate over all counts with their lowers and highest equivalent values:

```zig
var iter = h.iterator();

while (iter.next()) |bucket| {
    std.debug.print("count={d} in {d}..{d} range\n", .{bucket.count, bucket.lowest_equivalent_value, bucket.highest_equivalent_value});
}
```

## Merging histograms

If you have histograms of same type - you can just create histogram with `.counts` set to be a sum of other histograms `.counts`.

```zig
const other1: HdrHistogram(1, 10_000_000_000, .three_digits);
const other2: HdrHistogram(1, 10_000_000_000, .three_digits);
var sum: HdrHistogram(1, 10_000_000_000, .three_digits) = .{ .counts = other1.counts + other2.counts }; // Created counts from other histograms
```

Otherwise summing can be done by iterating over buckets and recording `lowest_equivalent_value` with respective count:

```zig
const other: HdrHistogram(1, 10_000_000_000, .three_digits);     // Leaves counts uninitizalized
var h: HdrHistogram(1, 10_000_000_000, .three_digits) = .init(); // Sets .counts to 0

var iter = other.iterator();
while (iter.next()) |bucket| {
    h.recordN(iter.lowest_equivalent_value, iter.count);
}
```

## Benchmarks

| Command | Mean [ms] | Min [ms] | Max [ms] | Relative |
|:---|---:|---:|---:|---:|
| `./c-recording/zig-out/bin/c_recording` | 25.1 ± 0.2 | 24.5 | 25.8 | 2.73 ± 4.04 |
| `./zig-recording/zig-out/bin/zig_recording` | 9.2 ± 13.6 | 7.4 | 126.1 | 1.00 |

Run `make bench` from `bench` directory to start benchmarks ([hyperfine](https://github.com/sharkdp/hyperfine) is required).

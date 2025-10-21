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
const HdrHistogram = @import("hdrhistogram_zig").HdrHistogram;

pub fn main() void {
    var h: HdrHistogram(1, 10_000_000_000, .three_digits) = .init(); // Initalized on stack
    h.record(1);
    h.record(2);
    h.record(3);

    std.debug.print("Mean: {d}\n", .{h.mean()});
}
```

Many methods are absent yet, but most common are implemented.
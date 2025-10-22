const std = @import("std");
const HdrHistogram = @import("hdrhistogram").HdrHistogram;

pub fn main() !void {
    var h: HdrHistogram(1, 3600 * 1000 * 1000, .three_digits) = .init();

    for (0..1_000_000) |_| {
        h.record(12340);
    }
}

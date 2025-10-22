const std = @import("std");
const c = @cImport({
    @cInclude("hdr/hdr_histogram.h");
});

pub fn main() !void {
    var h: [*c]c.hdr_histogram = undefined;
    if (c.hdr_init(1, c.INT64_C(3600 * 1000 * 1000), 3, &h) != 0) {
        @panic("failed to initalize hdrhistogram");
    }
    defer c.hdr_close(h);

    for (0..10_000_000) |_| {
        if (!c.hdr_record_value(h, 12340)) {
            @panic("failed to record response time to histogram");
        }
    }
}

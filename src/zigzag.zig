const std = @import("std");
const Writer = std.Io.Writer;

// Encoding format uses a ZigZag LEB128 encoded long. Positive values are counts,
// while negative values indicate a repeat zero counts.
pub fn zigZagEncode(longs: []const u64, w: *Writer) !void {
    var consequtive_zeroes: i64 = 0;

    for (longs) |l| {
        if (l == 0) {
            consequtive_zeroes += 1;
            continue;
        }

        if (consequtive_zeroes != 0) {
            try w.writeLeb128(-consequtive_zeroes);
            consequtive_zeroes = 0;
        }

        try w.writeLeb128(l);
    }

    if (consequtive_zeroes != 0) {
        try w.writeLeb128(-consequtive_zeroes);
        consequtive_zeroes = 0;
    }

    try w.flush();
}

const t = std.testing;

test zigZagEncode {
    var buffer: [16]u8 = undefined;

    {
        var w: Writer = .fixed(&buffer);
        try zigZagEncode(&.{56}, &w);
        try t.expectEqualSlices(u8, &.{56}, buffer[0..w.end]);
    }

    {
        var w: Writer = .fixed(&buffer);
        try zigZagEncode(&.{0}, &w);
        try t.expectEqualSlices(u8, &.{127}, buffer[0..w.end]); // -1 is 0x7F (or 127)
    }

    {
        var w: Writer = .fixed(&buffer);
        try zigZagEncode(&.{ 56, 0, 0, 0, 0, 57 }, &w);
        try t.expectEqualSlices(u8, &.{ 56, 124, 57 }, buffer[0..w.end]);
    }
}

//! Implementation of HdrHistogram – https://hdrhistogram.github.io/HdrHistogram/
//!
//! For explanation you can read Java/C/Go implementation or https://www.david-andrzejewski.com/publications/hdr.pdf

const std = @import("std");
const math = std.math;

const zigZagEncode = @import("zigzag.zig").zigZagEncode;

pub const SignificantValueDigits = enum(u3) {
    /// Observation x should be placed in a bin with boundaries no further than 10% from x.
    one_digit = 1,
    /// Observation x should be placed in a bin with boundaries no further than 1% from x.
    two_digits = 2,
    /// Observation x should be placed in a bin with boundaries no further than 0.1% from x.
    three_digits = 3,
    /// Observation x should be placed in a bin with boundaries no further than 0.01% from x.
    four_digits = 4,
    /// Observation x should be placed in a bin with boundaries no further than 0.001% from x.
    five_digits = 5,
};

const V2EncodingCookie = 0x1c849303;
const V2CompressedEncodingCookie = 0x1c849304;

/// A Histogram is a lossy data structure used to record the distribution of
/// non-normally distributed data (like latency) with a high degree of accuracy
/// and a bounded degree of precision.
pub fn HdrHistogram(
    /// The lowest value that can be discerned (distinguished from 0) by the histogram.
    /// May be internally rounded down to nearest power of 2
    comptime lowest_discernible_value: comptime_int,
    /// The highest value to be tracked by the histogram. Must be a positive
    /// integer that is >= (2 * lowestDiscernibleValue).
    comptime highest_trackable_value: comptime_int,
    /// Specifies the precision to use. This is the number of significant
    /// decimal digits to which the histogram will maintain value resolution
    /// and separation.
    comptime significant_value_digits: SignificantValueDigits,
) type {
    // Given a 3 decimal point accuracy, the expectation is obviously for "+/- 1 unit at 1000". It also means that
    // it's "ok to be +/- 2 units at 2000". The "tricky" thing is that it is NOT ok to be +/- 2 units at 1999. Only
    // starting at 2000. So internally, we need to maintain single unit resolution to 2x 10^decimalPoints.
    const largest_value_with_single_unit_resolution = 2 * math.pow(u64, 10, @intFromEnum(significant_value_digits));

    // We need to maintain power-of-two subBucketCount (for clean direct indexing) that is large enough to
    // provide unit resolution to at least largestValueWithSingleUnitResolution. So figure out
    // largestValueWithSingleUnitResolution's nearest power-of-two (rounded up), and use that:
    const sub_bucket_count_magnitude = @as(u32, @intFromFloat(math.ceil(math.log2(@as(f64, @floatFromInt(largest_value_with_single_unit_resolution))))));
    const sub_bucket_half_count_magnitude = sub_bucket_count_magnitude - 1;
    if (sub_bucket_half_count_magnitude == 0) {
        sub_bucket_half_count_magnitude = 1;
    }

    const unit_magnitude = @as(u32, @intFromFloat(math.floor(math.log2(@as(f64, @floatFromInt(lowest_discernible_value))))));

    const sub_bucket_count = math.pow(u64, 2, sub_bucket_half_count_magnitude + 1);
    const sub_bucket_half_count: u64 = sub_bucket_count / 2;
    const sub_bucket_mask = (sub_bucket_count - 1) << unit_magnitude;

    // determine exponent range needed to support the trackable value with no overflow:
    const smallest_untrackable_value = sub_bucket_count << unit_magnitude;

    comptime var buckets_needed = 1; // always have at least 1 bucket
    comptime var s = smallest_untrackable_value;
    while (s < highest_trackable_value) {
        if (s > math.maxInt(u64) / 2) {
            // next shift will overflow, meaning that bucket could represent values up to ones greater than
            // math.maxInt(u64), so it's the last bucket
            buckets_needed += 1;
            break;
        }

        s <<= 1;
        buckets_needed += 1;
    }

    return struct {
        const Self = @This();

        // TODO: Add counts_type in type definition to allow more compact representation of counts
        counts: [(buckets_needed + 1) * (sub_bucket_count / 2)]u64,
        total_count: u64 = 0,

        /// Creates HdrHistogram with counts initizalized as 0.
        pub fn init() Self {
            var self: Self = .{ .counts = undefined };
            @memset(&self.counts, 0);
            return self;
        }

        /// Returns recorded count for value.
        ///
        /// Values with same lowest_equivalent_value are considered equal and contribute to same counter.
        pub fn count(self: *const Self, value: u64) u64 {
            return self.counts[countsIndexFor(value)];
        }

        /// Records one occurance for value.
        ///
        /// Values with same lowest_equivalent_value are considered equal and contribute to same counter.
        pub fn record(self: *Self, value: u64) void {
            self.recordN(value, 1);
        }

        /// Records N occurances for value.
        ///
        /// Values with same lowest_equivalent_value are considered equal and contribute to same counter.
        pub fn recordN(self: *Self, value: u64, n: u64) void {
            self.counts[countsIndexFor(value)] += n;
            self.total_count += n;
        }

        /// Returns lowest bound for equivalent range for value.
        ///
        /// All values in equivalent range are considered equal.
        pub fn lowestEquivalentValue(_: *const Self, value: u64) u64 {
            const bucket_index = getBucketIndexFor(value);
            const sub_bucket_index = getSubBucketIndexFor(value, bucket_index);
            return valueFromIndex(bucket_index, sub_bucket_index);
        }

        /// Returns highest bound for equivalent range for value (bounds are inclusive).
        ///
        /// All values in equivalent range are considered equal.
        pub fn highestEquivalentValue(_: *const Self, value: u64) u64 {
            const bucket_index = getBucketIndexFor(value);
            const sub_bucket_index = getSubBucketIndexFor(value, bucket_index);
            return valueFromIndex(bucket_index, sub_bucket_index) + sizeOfEquivalentValueRange(bucket_index, sub_bucket_index) - 1;
        }

        /// Returns maximum of all recorded values.
        pub fn max(self: *const Self) u64 {
            var m: u64 = 0;
            var i = self.iterator();
            while (i.next()) |bucket| {
                if (bucket.count != 0) {
                    m = bucket.highest_equivalent_value;
                }
            }
            return m;
        }

        /// Returns minimum of all recorded values.
        pub fn min(self: *const Self) u64 {
            var m: u64 = 0;
            var i = self.iterator();
            while (i.next()) |bucket| {
                if (bucket.count != 0 and m == 0) {
                    m = bucket.highest_equivalent_value;
                    break;
                }
            }
            return self.lowestEquivalentValue(m);
        }

        /// Returns mean of all recorded values.
        pub fn mean(self: *const Self) u64 {
            if (self.total_count == 0) {
                return 0;
            }

            var sum: u64 = 0.0;
            var i = self.iterator();
            while (i.next()) |bucket| {
                if (bucket.count != 0) {
                    sum += bucket.count * bucket.median_equivalent_value();
                }
            }

            return sum / self.total_count;
        }

        /// Returns standard deviation of all recorded values.
        pub fn stdDev(self: *const Self) u64 {
            if (self.total_count == 0) {
                return 0;
            }

            const mean_: i64 = @intCast(self.mean());
            var geometric_dev_total: u64 = 0.0;

            var i = self.iterator();
            while (i.next()) |bucket| {
                if (bucket.count != 0) {
                    const dev: i64 = @as(i64, @intCast(bucket.median_equivalent_value())) - mean_;
                    geometric_dev_total += @as(u64, @intCast(dev * dev)) * bucket.count;
                }
            }

            return math.sqrt(geometric_dev_total / self.total_count);
        }

        /// Returns percentile values for provided percentile targets.
        /// targets must be sorted in ascending order and contain values from 0.0 to 100.0 range.
        pub fn percentiles(self: *const Self, comptime targets: []const f64) [targets.len]u64 {
            std.debug.assert(std.sort.isSorted(f64, targets, {}, std.sort.asc(f64)));

            var results: [targets.len]u64 = .{0} ** targets.len;
            if (self.total_count == 0 or targets.len == 0) {
                return results;
            }

            const tc: f64 = @floatFromInt(self.total_count);
            var iter = self.iterator().percentile();
            var current_percentile = iter.next();
            for (targets, 0..) |target, i| {
                const target_count = (target / 100.0) * tc;
                while (current_percentile) |p| : (current_percentile = iter.next()) {
                    if (@as(f64, @floatFromInt(p.cumulative_count)) >= target_count) {
                        results[i] = p.value;
                        break;
                    }
                }
            }
            return results;
        }

        /// Adds counts from other HdrHistogram and updates total_count.
        pub fn merge(self: *Self, other: *const Self) void {
            for (other.counts, 0..) |c, i| {
                self.counts[i] += c;
            }
            self.total_count += other.total_count;
        }

        // ┌───────────────────────────────────────────────────────────────────┐
        // │ Encoding                                                          │
        // └───────────────────────────────────────────────────────────────────┘

        /// Writes counts and metadata from histogram to Writer in zig-zag
        /// encoding (but with standard Leb128 encoding of counts)
        ///
        /// This is no-compatible encoding with V2 encoding format from HdrHistogram
        pub fn encode(self: *const Self, w: *std.Io.Writer) !void {
            try w.writeInt(u64, lowest_discernible_value, .big);
            try w.writeInt(u64, highest_trackable_value, .big);
            try w.writeInt(u8, @intFromEnum(significant_value_digits), .big);

            // From metadata size of counts is computable
            try zigZagEncode(self.counts, w);
        }

        // ┌───────────────────────────────────────────────────────────────────┐
        // │ Iterators imlementations                                          │
        // └───────────────────────────────────────────────────────────────────┘

        /// Returns iterator over all buckets (including empty ones).
        pub fn iterator(self: *const Self) Iterator {
            return .{ .histogram = self };
        }

        pub const Iterator = struct {
            histogram: *const Self,

            bucket_index: u64 = 0,
            sub_bucket_index: u64 = 0,

            /// Wraps copy of Iterator and produces iterator, that reports percentiles
            pub fn percentile(iter: *const Iterator) PercentileIterator {
                return .{ .iterator = iter.*, .total_count = @floatFromInt(iter.histogram.total_count) };
            }

            pub fn next(iter: *Iterator) ?Bucket {
                if (iter.sub_bucket_index >= sub_bucket_count) {
                    iter.sub_bucket_index = sub_bucket_half_count;
                    iter.bucket_index += 1;
                }

                const index = countsIndex(iter.bucket_index, iter.sub_bucket_index);
                if (index >= iter.histogram.counts.len) {
                    return null;
                }

                defer iter.sub_bucket_index += 1;

                const leq = valueFromIndex(iter.bucket_index, iter.sub_bucket_index);
                const heq = leq + sizeOfEquivalentValueRange(iter.bucket_index, iter.sub_bucket_index) - 1;

                return Bucket{
                    .count = iter.histogram.counts[index],
                    .lowest_equivalent_value = leq,
                    .highest_equivalent_value = heq,
                };
            }

            const Bucket = struct {
                count: u64,
                lowest_equivalent_value: u64,
                highest_equivalent_value: u64,

                pub fn median_equivalent_value(self: *const Bucket) u64 {
                    return self.lowest_equivalent_value / 2 + self.highest_equivalent_value / 2 + 1;
                }
            };
        };

        pub const PercentileIterator = struct {
            iterator: Iterator,

            total_count: f64,
            cumulative_count: u64 = 0,

            pub fn next(self: *PercentileIterator) ?Percentile {
                while (self.iterator.next()) |bucket| {
                    if (bucket.count != 0) {
                        self.cumulative_count += bucket.count;

                        return .{
                            .value = bucket.highest_equivalent_value,
                            .cumulative_count = self.cumulative_count,
                            .percentile = @as(f64, @floatFromInt(self.cumulative_count)) / self.total_count * 100.0,
                        };
                    }
                }
                return null;
            }

            pub const Percentile = struct {
                value: u64,
                percentile: f64,
                cumulative_count: u64,
            };
        };

        // ┌────────────────────────────────────────────────────────────────────────────────┐
        // │ Internal methods to work with bucket_index+sub_bucket_index and counts indexes │
        // └────────────────────────────────────────────────────────────────────────────────┘

        /// Returns lowest equivalent value for (bucket_index, sub_bucket_index) pair
        fn valueFromIndex(bucket_index: u64, sub_bucket_index: u64) u64 {
            return sub_bucket_index << @as(u6, @intCast(bucket_index + unit_magnitude));
        }

        /// Returns lowest equivalent value for index in counts array
        fn valueForIndex(index: u64) u64 {
            var bucket_index = (index >> @as(u6, @intCast(sub_bucket_half_count_magnitude))) - 1;
            var sub_bucket_index = (index & (sub_bucket_half_count - 1)) + sub_bucket_half_count;

            if (bucket_index < 0) {
                sub_bucket_index -= sub_bucket_half_count;
                bucket_index = 0;
            }

            return valueFromIndex(bucket_index, sub_bucket_index);
        }

        fn sizeOfEquivalentValueRange(bucket_index: u64, sub_bucket_index: u64) u64 {
            var adjusted_bucket_index = bucket_index;
            if (sub_bucket_index >= sub_bucket_count) {
                adjusted_bucket_index += 1;
            }

            return @as(u64, 1) << @as(u6, @intCast(unit_magnitude + adjusted_bucket_index));
        }

        fn countsIndex(bucket_index: u64, sub_bucket_index: u64) u64 {
            return getBucketBaseIndex(bucket_index) + sub_bucket_index - sub_bucket_half_count;
        }

        fn getBucketBaseIndex(bucket_index: u64) u64 {
            return (bucket_index + 1) << @as(u6, @intCast(sub_bucket_half_count_magnitude));
        }

        fn getBucketIndexFor(value: u64) u64 {
            const pow2_ceiling = 64 - @clz(value | sub_bucket_mask);
            return pow2_ceiling - unit_magnitude - (sub_bucket_half_count_magnitude + 1);
        }

        fn getSubBucketIndexFor(value: u64, bucket_index: u64) u64 {
            return value >> @as(u6, @intCast(bucket_index + unit_magnitude));
        }

        fn countsIndexFor(value: u64) u64 {
            const bucket_index = getBucketIndexFor(value);
            const sub_bucket_index = getSubBucketIndexFor(value, bucket_index);
            return countsIndex(bucket_index, sub_bucket_index);
        }
    };
}

const expectEqual = std.testing.expectEqual;

const LOWEST = 1;
const HIGHEST = 3600_000_000;
const SIGNIFICANT = SignificantValueDigits.three_digits;
const TEST_VALUE_LEVEL = 4;

test "basic" {
    const h: HdrHistogram(LOWEST, HIGHEST, SIGNIFICANT) = .init();
    // try expectEqual(0, h.unit_magnitude);
    // try expectEqual(10, h.sub_bucket_half_count_magnitude);
    // try expectEqual(22, h.bucket_count);
    // try expectEqual(2048, h.sub_bucket_count);
    try expectEqual(23552, h.counts.len);
}

test "record value" {
    var h: HdrHistogram(LOWEST, HIGHEST, SIGNIFICANT) = .init();
    h.record(TEST_VALUE_LEVEL);
    try expectEqual(1, h.count(TEST_VALUE_LEVEL));
}

test "empty histogram" {
    const h: HdrHistogram(LOWEST, HIGHEST, SIGNIFICANT) = .init();
    try expectEqual(0, h.min());
    try expectEqual(0, h.max());
    try expectEqual(0, h.mean());
    try expectEqual(0, h.stdDev());
}

test "highest equivalent value" {
    const h: HdrHistogram(LOWEST, HIGHEST, SIGNIFICANT) = .init();
    try expectEqual(8183 * 1024 + 1023, h.highestEquivalentValue(8180 * 1024));
    try expectEqual(8191 * 1024 + 1023, h.highestEquivalentValue(8191 * 1024));
    try expectEqual(8199 * 1024 + 1023, h.highestEquivalentValue(8193 * 1024));
    try expectEqual(9999 * 1024 + 1023, h.highestEquivalentValue(9995 * 1024));
    try expectEqual(10007 * 1024 + 1023, h.highestEquivalentValue(10007 * 1024));
    try expectEqual(10015 * 1024 + 1023, h.highestEquivalentValue(10008 * 1024));
}

test "value at percentile" {
    var h: HdrHistogram(LOWEST, 10000000, SIGNIFICANT) = .init();
    for (0..1000000) |i| {
        h.record(i);
    }

    const percentiles = h.percentiles(&.{ 50.0, 75.0, 90.0, 95.0, 99.0, 99.9, 99.99 });

    try std.testing.expectEqualSlices(u64, &.{ 500223, 750079, 900095, 950271, 990207, 999423, 999935 }, &percentiles);
}

test "small histogram percentiles" {
    var h: HdrHistogram(LOWEST, 10000000, SIGNIFICANT) = .init();
    const v = LOWEST + 1;
    h.record(v);

    const percentiles = h.percentiles(&.{ 50.0, 75.0, 90.0, 95.0, 99.0, 99.9, 99.999, 100.0 });
    const expected: []const u64 = &.{ v, v, v, v, v, v, v, v };
    try std.testing.expectEqualSlices(u64, expected, &percentiles);
}

test "mean" {
    var h: HdrHistogram(LOWEST, HIGHEST, SIGNIFICANT) = .init();
    for (0..1000000) |i| {
        h.record(i);
    }
    try expectEqual(500000, h.mean());
}

test "stdDev" {
    var h: HdrHistogram(LOWEST, HIGHEST, SIGNIFICANT) = .init();
    var total: f64 = 0.0;
    for (0..1000000) |i| {
        total += std.math.pow(f64, @as(f64, @floatFromInt(i)) - 500000.0, 2);
        h.record(i);
    }
    const variance = total / 999999.0;
    const stdDev = std.math.sqrt(variance);
    try expectEqual(@as(u64, @intFromFloat(stdDev)), h.stdDev());
}

test "max" {
    var h: HdrHistogram(LOWEST, HIGHEST, SIGNIFICANT) = .init();
    for (0..1000000) |i| {
        h.record(i);
    }
    try expectEqual(1000447, h.max());
}

test "min" {
    var h: HdrHistogram(LOWEST, HIGHEST, SIGNIFICANT) = .init();
    for (0..1000000) |i| {
        h.record(i);
    }
    try expectEqual(0, h.min());
}

test "size" {
    try expectEqual(204808, @sizeOf(HdrHistogram(1, 10_000_000_000, .three_digits)));
}

test "merge" {
    var h1: HdrHistogram(LOWEST, HIGHEST, SIGNIFICANT) = .init();
    h1.record(LOWEST + 1);
    h1.record(LOWEST + 1000);

    var h2: HdrHistogram(LOWEST, HIGHEST, SIGNIFICANT) = .init();
    h2.record(LOWEST + 1);
    h2.record(LOWEST + 2000);

    h1.merge(&h2);

    try expectEqual(4, h1.total_count);
    try expectEqual(2, h1.count(LOWEST + 1));
    try expectEqual(1, h1.count(LOWEST + 1000));
    try expectEqual(1, h1.count(LOWEST + 2000));
}

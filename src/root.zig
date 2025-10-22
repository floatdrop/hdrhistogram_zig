//! Implementation of HdrHistogram – https://hdrhistogram.github.io/HdrHistogram/
//!
//! For explanation you can read Java/C/Go implementation or https://www.david-andrzejewski.com/publications/hdr.pdf

const std = @import("std");
const math = std.math;

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

        bucket_count: u64 = buckets_needed,
        sub_bucket_count: u64 = sub_bucket_count,
        sub_bucket_half_count: u64 = (sub_bucket_count / 2),
        sub_bucket_half_count_magnitude: u64 = sub_bucket_half_count_magnitude,
        sub_bucket_mask: u64 = sub_bucket_mask,
        total_count: u64 = 0,
        unit_magnitude: u64 = unit_magnitude,
        counts: [(buckets_needed + 1) * (sub_bucket_count / 2)]u64,

        /// Creates HdrHistogram with counts initizalized as 0.
        pub fn init() Self {
            var self: Self = .{ .counts = undefined };
            @memset(&self.counts, 0);
            return self;
        }

        /// Creates HdrHistogram with counts uninitizalized.
        pub fn initUndefined() Self {
            return Self{ .counts = undefined };
        }

        /// Returns recorded count for value.
        ///
        /// Values with same lowestEquivalentValue are considered equal and contribute to same counter.
        pub fn count(self: *const Self, value: u64) u64 {
            return self.counts[self.countsIndexFor(value)];
        }

        /// Records one occurance for value.
        ///
        /// Values with same lowestEquivalentValue are considered equal and contribute to same counter.
        pub fn record(self: *Self, value: u64) void {
            self.recordN(value, 1);
        }

        /// Records N occurances for value.
        ///
        /// Values with same lowestEquivalentValue are considered equal and contribute to same counter.
        pub fn recordN(self: *Self, value: u64, n: u64) void {
            self.counts[self.countsIndexFor(value)] += n;
            self.total_count += n;
        }

        /// Returns lowest bound for equivalent range for value.
        ///
        /// All values in equivalent range are considered equal.
        pub fn lowestEquivalentValue(self: *const Self, value: u64) u64 {
            const bucket_index = self.getBucketIndexFor(value);
            const sub_bucket_index = self.getSubBucketIndexFor(value, bucket_index);
            return self.valueFromIndex(bucket_index, sub_bucket_index);
        }

        /// Returns highest bound for equivalent range for value (bounds are inclusive).
        ///
        /// All values in equivalent range are considered equal.
        pub fn highestEquivalentValue(self: *const Self, value: u64) u64 {
            const bucket_index = self.getBucketIndexFor(value);
            const sub_bucket_index = self.getSubBucketIndexFor(value, bucket_index);
            return self.valueFromIndex(bucket_index, sub_bucket_index) + self.sizeOfEquivalentValueRange(bucket_index, sub_bucket_index) - 1;
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

            var total: u64 = 0.0;
            var i = self.iterator();
            while (i.next()) |bucket| {
                if (bucket.count != 0) {
                    total += bucket.count * bucket.median_equivalent_value();
                }
            }

            return total / self.total_count;
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

        /// Returns percentile value.
        ///
        /// That is value, which is greater than percentile% of recorded values.
        pub fn valueAtPercentile(self: *const Self, percentile: f64) u64 {
            const p = math.clamp(percentile, 0.0, 100.0);

            const count_at_percentile: u64 = self.total_count * @as(u64, @intFromFloat(p * 100000)) / (100 * 100000); // scaling p to 5 digits beyond point
            var count_up_to_index: u64 = 0;
            var value_at_count: u64 = 0;
            for (0..self.counts.len) |i| {
                if (self.counts[i] != 0) {
                    count_up_to_index += self.counts[i];

                    if (count_up_to_index >= count_at_percentile) {
                        value_at_count = self.valueForIndex(i);
                        break;
                    }
                }
            }

            if (p == 0.0) {
                return self.lowestEquivalentValue(value_at_count);
            }
            return self.highestEquivalentValue(value_at_count);
        }

        /// Returns iterator over all buckets (including empty ones).
        ///
        /// Iterator must outlive histogram struct.
        pub fn iterator(self: *const Self) Iterator {
            return .{ .histogram = self };
        }

        pub const Iterator = struct {
            histogram: *const Self,

            bucket_index: u64 = 0,
            sub_bucket_index: u64 = 0,

            pub fn next(iter: *Iterator) ?Bucket {
                if (iter.sub_bucket_index >= iter.histogram.sub_bucket_count) {
                    iter.sub_bucket_index = iter.histogram.sub_bucket_half_count;
                    iter.bucket_index += 1;
                }

                const index = iter.histogram.countsIndex(iter.bucket_index, iter.sub_bucket_index);
                if (index >= iter.histogram.counts.len) {
                    return null;
                }

                defer iter.sub_bucket_index += 1;

                const leq = iter.histogram.valueFromIndex(iter.bucket_index, iter.sub_bucket_index);
                const heq = leq + iter.histogram.sizeOfEquivalentValueRange(iter.bucket_index, iter.sub_bucket_index) - 1;

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

        // ┌────────────────────────────────────────────────────────────────────────────────┐
        // │ Internal methods to work with bucket_index+sub_bucket_index and counts indexes │
        // └────────────────────────────────────────────────────────────────────────────────┘

        /// Returns lowest equivalent value for (bucket_index, sub_bucket_index) pair
        fn valueFromIndex(self: *const Self, bucket_index: u64, sub_bucket_index: u64) u64 {
            return sub_bucket_index << @as(u6, @intCast(bucket_index + self.unit_magnitude));
        }

        /// Returns lowest equivalent value for index in counts array
        fn valueForIndex(self: *const Self, index: u64) u64 {
            var bucket_index = (index >> @as(u6, @intCast(self.sub_bucket_half_count_magnitude))) - 1;
            var sub_bucket_index = (index & (self.sub_bucket_half_count - 1)) + self.sub_bucket_half_count;

            if (bucket_index < 0) {
                sub_bucket_index -= self.sub_bucket_half_count;
                bucket_index = 0;
            }

            return self.valueFromIndex(bucket_index, sub_bucket_index);
        }

        fn sizeOfEquivalentValueRange(self: *const Self, bucket_index: u64, sub_bucket_index: u64) u64 {
            var adjusted_bucket_index = bucket_index;
            if (sub_bucket_index >= self.sub_bucket_count) {
                adjusted_bucket_index += 1;
            }

            return @as(u64, 1) << @as(u6, @intCast(self.unit_magnitude + adjusted_bucket_index));
        }

        fn countsIndex(self: *const Self, bucket_index: u64, sub_bucket_index: u64) u64 {
            return self.getBucketBaseIndex(bucket_index) + sub_bucket_index - self.sub_bucket_half_count;
        }

        fn getBucketBaseIndex(self: *const Self, bucket_index: u64) u64 {
            return (bucket_index + 1) << @as(u6, @intCast(self.sub_bucket_half_count_magnitude));
        }

        fn getBucketIndexFor(self: *const Self, value: u64) u64 {
            const pow2_ceiling = 64 - @clz(value | self.sub_bucket_mask);
            return pow2_ceiling - self.unit_magnitude - (self.sub_bucket_half_count_magnitude + 1);
        }

        fn getSubBucketIndexFor(self: *const Self, value: u64, bucket_index: u64) u64 {
            return value >> @as(u6, @intCast(bucket_index + self.unit_magnitude));
        }

        fn countsIndexFor(self: *const Self, value: u64) u64 {
            const bucket_index = self.getBucketIndexFor(value);
            const sub_bucket_index = self.getSubBucketIndexFor(value, bucket_index);
            return self.countsIndex(bucket_index, sub_bucket_index);
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
    try expectEqual(0, h.unit_magnitude);
    try expectEqual(10, h.sub_bucket_half_count_magnitude);
    try expectEqual(22, h.bucket_count);
    try expectEqual(2048, h.sub_bucket_count);
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

    try expectEqual(500223, h.valueAtPercentile(50.0));
    try expectEqual(750079, h.valueAtPercentile(75.0));
    try expectEqual(900095, h.valueAtPercentile(90.0));
    try expectEqual(950271, h.valueAtPercentile(95.0));
    try expectEqual(990207, h.valueAtPercentile(99.0));
    try expectEqual(999423, h.valueAtPercentile(99.9));
    try expectEqual(999935, h.valueAtPercentile(99.99));
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

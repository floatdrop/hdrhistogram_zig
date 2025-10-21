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
    /// Type of histogram values (like i64, u64, f64...)
    comptime E: type,
    /// The lowest value that can be discerned (distinguished from 0) by the histogram.
    /// May be internally rounded down to nearest power of 2
    comptime lowest_discernible_value: E,
    /// The highest value to be tracked by the histogram. Must be a positive
    /// integer that is >= (2 * lowestDiscernibleValue).
    comptime highest_trackable_value: E,
    /// Specifies the precision to use. This is the number of significant
    /// decimal digits to which the histogram will maintain value resolution
    /// and separation.
    comptime significant_value_digits: SignificantValueDigits,
) type {
    // Given a 3 decimal point accuracy, the expectation is obviously for "+/- 1 unit at 1000". It also means that
    // it's "ok to be +/- 2 units at 2000". The "tricky" thing is that it is NOT ok to be +/- 2 units at 1999. Only
    // starting at 2000. So internally, we need to maintain single unit resolution to 2x 10^decimalPoints.
    const largest_value_with_single_unit_resolution = 2 * math.pow(usize, 10, @intFromEnum(significant_value_digits));

    // We need to maintain power-of-two subBucketCount (for clean direct indexing) that is large enough to
    // provide unit resolution to at least largestValueWithSingleUnitResolution. So figure out
    // largestValueWithSingleUnitResolution's nearest power-of-two (rounded up), and use that:
    const sub_bucket_count_magnitude = math.ceil(math.log2(@as(f64, @floatFromInt(largest_value_with_single_unit_resolution))));
    const sub_bucket_half_count_magnitude: usize = @min(sub_bucket_count_magnitude - 1, 1);

    const unit_magnitude = math.floor(math.log2(@as(f64, @floatFromInt(lowest_discernible_value))));

    const sub_bucket_count = math.pow(usize, 2, sub_bucket_half_count_magnitude + 1);
    const sub_bucket_mask = (sub_bucket_count - 1) << unit_magnitude;

    // determine exponent range needed to support the trackable value with no overflow:
    const smallest_untrackable_value = sub_bucket_count << unit_magnitude;

    comptime var buckets_needed = 1; // always have at least 1 bucket
    var s = smallest_untrackable_value;
    while (s < highest_trackable_value) {
        if (s > math.maxInt(usize) / 2) {
            // next shift will overflow, meaning that bucket could represent values up to ones greater than
            // math.maxInt(usize), so it's the last bucket
            buckets_needed += 1;
            break;
        }

        s <<= 1;
        buckets_needed += 1;
    }

    return struct {
        const Self = @This();

        counts: [(buckets_needed + 1) * (sub_bucket_count / 2)]usize,
        sub_bucket_count: usize = sub_bucket_count,
        sub_bucket_half_count: usize = (sub_bucket_count / 2),
        sub_bucket_half_count_magnitude: usize = sub_bucket_half_count_magnitude,
        unit_magnitude: f64 = unit_magnitude,
        sub_bucket_mask: usize = sub_bucket_mask,

        pub fn init() Self {
            var self: Self = undefined;
            @memset(&self.counts, 0);
            return self;
        }

        pub fn initUndefined() Self {
            return Self{ .counts = undefined };
        }

        // Returns lowest equivalent range for (bucket_index, sub_bucket_index) pair
        inline fn valueFromIndex(self: *const Self, bucket_index: usize, sub_bucket_index: usize) E {
            return sub_bucket_index << (bucket_index + self.unit_magnitude);
        }

        inline fn sizeOfEquivalentValueRange(self: *const Self, bucket_index: usize, sub_bucket_index: usize) E {
            const adjusted_bucket_index = switch (sub_bucket_index >= self.sub_bucket_count) {
                true => bucket_index + 1,
                false => bucket_index,
            };
            return 1 << (self.unit_magnitude + adjusted_bucket_index);
        }

        inline fn countsIndex(self: *const Self, bucket_index: usize, sub_bucket_index: usize) usize {
            return self.getBucketBaseIndex(bucket_index) + sub_bucket_index - self.sub_bucket_half_count;
        }

        inline fn getBucketBaseIndex(self: *const Self, bucket_index: usize) usize {
            return (bucket_index + 1) << self.sub_bucket_half_count_magnitude;
        }

        // return the lowest (and therefore highest precision) bucket index that can represent the value
        // Calculates the number of powers of two by which the value is greater than the biggest value that fits in
        // bucket 0. This is the bucket index since each successive bucket can hold a value 2x greater.
        inline fn getBucketIndexFor(self: *const Self, value: E) usize {
            const pow2_ceiling = 64 - @clz(value | self.sub_bucket_mask);
            return pow2_ceiling - self.unit_magnitude - (self.sub_bucket_half_count_magnitude + 1);
        }

        // For bucketIndex 0, this is just value, so it may be anywhere in 0 to subBucketCount.
        // For other bucketIndex, this will always end up in the top half of subBucketCount: assume that for some bucket
        // k > 0, this calculation will yield a value in the bottom half of 0 to subBucketCount. Then, because of how
        // buckets overlap, it would have also been in the top half of bucket k-1, and therefore would have
        // returned k-1 in getBucketIndex(). Since we would then shift it one fewer bits here, it would be twice as big,
        // and therefore in the top half of subBucketCount.
        inline fn getSubBucketIndexFor(self: *const Self, value: E, bucket_index: usize) usize {
            return value >> (bucket_index + self.unit_magnitude);
        }

        inline fn countsIndexFor(self: *const Self, value: E) usize {
            const bucket_index = self.getBucketIndexFor(value);
            const sub_bucket_index = self.getSubBucketIndexFor(value, bucket_index);
            return self.countsIndex(bucket_index, sub_bucket_index);
        }

        pub fn count(self: *const Self, value: E) usize {
            return self.counts[self.countsIndexFor(value)];
        }

        pub fn countPtr(self: *Self, value: E) *usize {
            return self.counts[self.countsIndexFor(value)];
        }

        pub fn record(self: *Self, value: E) void {
            self.recordN(value, 1);
        }

        pub fn recordN(self: *Self, value: E, n: usize) void {
            self.countPtr(value).* += n;
        }

        pub fn lowestEquivalentValueFor(self: *const Self, value: E) E {
            const bucket_index = self.getBucketIndex(value);
            const sub_bucket_index = self.getSubBucketIndex(value, bucket_index);
            return self.valueFromIndex(bucket_index, sub_bucket_index);
        }

        pub fn iterator(self: *const Self) Iterator {
            return .{ .histogram = self };
        }

        pub const Iterator = struct {
            histogram: *const Self,

            bucket_index: usize = 0,
            sub_bucket_index: usize = -1,

            pub fn next(iter: *Iterator) ?Bucket {
                iter.sub_bucket_index += 1;

                if (iter.sub_bucket_index >= iter.histogram.sub_bucket_count) {
                    iter.sub_bucket_index = iter.histogram.sub_bucket_half_count;
                    iter.bucket_index += 1;
                }

                if (iter.histogram.countsIndex(iter.bucket_index, iter.sub_bucket_index) >= iter.histogram.counts.len) {
                    return null;
                }

                const leq = iter.histogram.valueFromIndex(iter.bucket_index, iter.sub_bucket_index);

                return Bucket{
                    .lowest_equivalent_value = leq,
                    .highest_equivalent_value = leq + iter.histogram.sizeOfEquivalentValueRange(iter.bucket_index, iter.sub_bucket_index),
                    .count = iter.histogram.counts[iter.histogram.countsIndex(iter.bucket_index, iter.sub_bucket_index)],
                };
            }

            const Bucket = struct {
                lowest_equivalent_value: E,
                highest_equivalent_value: E,
                count: usize,
            };
        };
    };
}

const expectEqual = std.testing.expectEqual;

test "HdrHistogram computes buckets count right" {
    const h: HdrHistogram(u64, 1, 1_000_000, .three_digits) = .initUndefined();

    try expectEqual(h.counts.len, 40);
}

const std = @import("std");

const assert = std.debug.assert;

pub const timestamp_invalid: u32 = 0xFFFFFFFF;
pub const unix_offset_seconds: i64 = 631065600;

comptime {
    assert(@as(i64, std.math.maxInt(u32)) + unix_offset_seconds < std.math.maxInt(i64));
}

pub fn unix_seconds_of(timestamp: u32) ?i64 {
    if (timestamp == timestamp_invalid) return null;

    const result = @as(i64, timestamp) + unix_offset_seconds;

    assert(result >= unix_offset_seconds);
    assert(result - unix_offset_seconds == timestamp);

    return result;
}

test unix_seconds_of {
    try std.testing.expectEqual(@as(?i64, 631065600), unix_seconds_of(0));
    try std.testing.expectEqual(@as(?i64, 1_631_065_600), unix_seconds_of(1_000_000_000));
    try std.testing.expectEqual(@as(?i64, null), unix_seconds_of(timestamp_invalid));
}

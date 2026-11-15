const std = @import("std");

const assert = std.debug.assert;

pub const Checksum = struct {
    value: u16,

    pub const empty: Checksum = .{ .value = 0 };

    pub fn update(checksum_state: *Checksum, bytes: []const u8) void {
        assert(bytes.len <= std.math.maxInt(u32));
        assert(tables[0][0] == 0);

        const chunk_count: u32 = @intCast(@divFloor(bytes.len, slice_bytes));
        const tail_start = chunk_count * slice_bytes;

        for (0..chunk_count) |chunk_index| {
            checksum_state.chunk_update(bytes[chunk_index * slice_bytes ..][0..slice_bytes]);
        }

        for (bytes[tail_start..]) |byte| {
            const index: u8 = @truncate(checksum_state.value ^ byte);

            checksum_state.value = (checksum_state.value >> 8) ^ tables[0][index];
        }

        assert(bytes.len - tail_start < slice_bytes);
    }

    fn chunk_update(checksum_state: *Checksum, chunk: *const [slice_bytes]u8) void {
        assert(chunk.len == slice_bytes);
        assert(tables.len == slice_bytes);

        const value = checksum_state.value;
        const low = @as(u8, @truncate(value)) ^ chunk[0];
        const high = @as(u8, @truncate(value >> 8)) ^ chunk[1];

        checksum_state.value = tables[7][low] ^ tables[6][high] ^
            tables[5][chunk[2]] ^ tables[4][chunk[3]] ^
            tables[3][chunk[4]] ^ tables[2][chunk[5]] ^
            tables[1][chunk[6]] ^ tables[0][chunk[7]];
    }
};

pub const checksum_bytes: u32 = 2;

const polynomial_reflected: u16 = 0xA001;
const slice_bytes: u32 = 8;
const tables = tables_build();

comptime {
    assert(checksum_bytes == @sizeOf(u16));
    assert(tables.len == slice_bytes);
    assert(tables[0][1] == 0xC0C1);
    assert(tables[0][0x80] == polynomial_reflected);
}

pub fn checksum(bytes: []const u8) u16 {
    assert(bytes.len <= std.math.maxInt(u32));

    var state: Checksum = .empty;

    state.update(bytes);

    if (bytes.len == 0) assert(state.value == 0);

    return state.value;
}

fn tables_build() [slice_bytes][256]u16 {
    @setEvalBranchQuota(20_000);

    var result: [slice_bytes][256]u16 = undefined;

    for (0..256) |index| {
        var value: u16 = @intCast(index);

        for (0..8) |_| {
            const carry = value & 1;

            value >>= 1;

            if (carry == 1) value ^= polynomial_reflected;
        }

        result[0][index] = value;
    }

    for (1..slice_bytes) |level| {
        for (0..256) |index| {
            const previous = result[level - 1][index];

            result[level][index] = (previous >> 8) ^ result[0][@as(u8, @truncate(previous))];
        }
    }

    assert(result[0][0] == 0);
    assert(result[1][0] == 0);

    return result;
}

test checksum {
    try std.testing.expectEqual(@as(u16, 0xBB3D), checksum("123456789"));
    try std.testing.expectEqual(@as(u16, 0), checksum(""));
    try std.testing.expect(checksum("hello") != checksum("olleh"));
}

test Checksum {
    var split: Checksum = .empty;

    split.update("hello ");
    split.update("world");

    try std.testing.expectEqual(checksum("hello world"), split.value);

    var seeded: Checksum = .{ .value = 0x1234 };

    seeded.update("");

    try std.testing.expectEqual(@as(u16, 0x1234), seeded.value);
}

test "the checksum agrees with the standard library CRC-16/ARC at every length and split" {
    var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const random = prng.random();

    var bytes: [3 * slice_bytes + 5]u8 = undefined;

    for (0..1_000) |_| {
        random.bytes(&bytes);

        const length = random.uintAtMost(u32, bytes.len);
        const split = random.uintAtMost(u32, length);
        const expected = std.hash.crc.@"CRC-16/ARC".hash(bytes[0..length]);

        var seeded: Checksum = .empty;

        seeded.update(bytes[0..split]);
        seeded.update(bytes[split..length]);

        try std.testing.expectEqual(expected, checksum(bytes[0..length]));
        try std.testing.expectEqual(expected, seeded.value);
    }
}

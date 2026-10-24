const std = @import("std");

const assert = std.debug.assert;

pub const checksum_bytes = 2;

const polynomial_reflected: u16 = 0xA001;
const slice_bytes = 8;
const tables = tables_build();

comptime {
    assert(checksum_bytes == @sizeOf(u16));
    assert(tables.len == slice_bytes);
    assert(tables[0][1] == 0xC0C1);
    assert(tables[0][0x80] == polynomial_reflected);
}

pub fn checksum(seed: u16, bytes: []const u8) u16 {
    const chunk_count = bytes.len / slice_bytes;
    const tail_start = chunk_count * slice_bytes;
    var value = seed;

    for (0..chunk_count) |chunk_index| {
        const chunk = bytes[chunk_index * slice_bytes ..][0..slice_bytes];

        value = update_chunk(value, chunk);
    }

    for (bytes[tail_start..]) |byte| {
        value = update_byte(value, byte);
    }

    assert(bytes.len - tail_start < slice_bytes);

    return value;
}

fn update_byte(value: u16, byte: u8) u16 {
    const index: u8 = @truncate(value ^ byte);

    return (value >> 8) ^ tables[0][index];
}

fn update_chunk(value: u16, chunk: *const [slice_bytes]u8) u16 {
    const low = @as(u8, @truncate(value)) ^ chunk[0];
    const high = @as(u8, @truncate(value >> 8)) ^ chunk[1];

    return tables[7][low] ^ tables[6][high] ^
        tables[5][chunk[2]] ^ tables[4][chunk[3]] ^
        tables[3][chunk[4]] ^ tables[2][chunk[5]] ^
        tables[1][chunk[6]] ^ tables[0][chunk[7]];
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

    return result;
}

test "checksum is seedable so a split pass equals a whole pass" {
    const whole = checksum(0, "hello world");
    const split = checksum(checksum(0, "hello "), "world");

    try std.testing.expectEqual(whole, split);
}

test "checksum depends on byte order" {
    try std.testing.expect(checksum(0, "hello") != checksum(0, "olleh"));
}

test "empty input leaves the seed unchanged" {
    try std.testing.expectEqual(@as(u16, 0x1234), checksum(0x1234, ""));
}

test "checksum matches the CRC-16/ARC check value" {
    try std.testing.expectEqual(@as(u16, 0xBB3D), checksum(0, "123456789"));
}

test "checksum agrees with the standard library CRC-16/ARC at every length and split" {
    var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const random = prng.random();
    var bytes: [3 * slice_bytes + 5]u8 = undefined;

    for (0..1_000) |_| {
        random.bytes(&bytes);

        const length = random.uintAtMost(usize, bytes.len);
        const split = random.uintAtMost(usize, length);
        const expected = std.hash.crc.@"CRC-16/ARC".hash(bytes[0..length]);
        const seeded = checksum(checksum(0, bytes[0..split]), bytes[split..length]);

        try std.testing.expectEqual(expected, checksum(0, bytes[0..length]));
        try std.testing.expectEqual(expected, seeded);
    }
}

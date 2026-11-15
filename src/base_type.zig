const std = @import("std");

const assert = std.debug.assert;

pub const BaseType = enum(u8) {
    enum_value = 0x00,
    sint8 = 0x01,
    uint8 = 0x02,
    string = 0x07,
    uint8z = 0x0A,
    byte = 0x0D,
    sint16 = 0x83,
    uint16 = 0x84,
    sint32 = 0x85,
    uint32 = 0x86,
    float32 = 0x88,
    float64 = 0x89,
    uint16z = 0x8B,
    uint32z = 0x8C,
    sint64 = 0x8E,
    uint64 = 0x8F,
    uint64z = 0x90,

    pub fn size_bytes(base_type: BaseType) u8 {
        const result: u8 = switch (base_type) {
            .enum_value, .sint8, .uint8, .string, .uint8z, .byte => 1,
            .sint16, .uint16, .uint16z => 2,
            .sint32, .uint32, .float32, .uint32z => 4,
            .float64, .sint64, .uint64, .uint64z => 8,
        };

        assert(result >= 1);
        assert(result <= element_bytes_max);

        return result;
    }

    pub fn invalid_value(base_type: BaseType) ?u64 {
        const result: ?u64 = switch (base_type) {
            .enum_value, .uint8, .byte => 0xFF,
            .sint8 => 0x7F,
            .uint16 => 0xFFFF,
            .sint16 => 0x7FFF,
            .uint32, .float32 => 0xFFFFFFFF,
            .sint32 => 0x7FFFFFFF,
            .uint64, .float64 => 0xFFFFFFFFFFFFFFFF,
            .sint64 => 0x7FFFFFFFFFFFFFFF,
            .uint8z, .uint16z, .uint32z, .uint64z => 0,
            .string => null,
        };

        if (result == null) assert(base_type == .string);
        if (base_type == .string) assert(result == null);

        return result;
    }

    pub fn is_signed(base_type: BaseType) bool {
        const result = switch (base_type) {
            .sint8, .sint16, .sint32, .sint64 => true,
            .enum_value, .uint8, .uint16, .uint32, .uint64 => false,
            .uint8z, .uint16z, .uint32z, .uint64z => false,
            .float32, .float64, .string, .byte => false,
        };

        if (result) assert(!base_type.is_float());

        return result;
    }

    pub fn is_float(base_type: BaseType) bool {
        const result = switch (base_type) {
            .float32, .float64 => true,
            .enum_value, .sint8, .uint8, .string, .uint8z, .byte => false,
            .sint16, .uint16, .uint16z => false,
            .sint32, .uint32, .uint32z => false,
            .sint64, .uint64, .uint64z => false,
        };

        if (result) assert(base_type.size_bytes() >= 4);

        return result;
    }
};

pub const element_bytes_max: u8 = 8;

comptime {
    @setEvalBranchQuota(10_000);

    for (std.enums.values(BaseType)) |base_type| {
        const size = base_type.size_bytes();

        assert(size >= 1);
        assert(size <= element_bytes_max);
        assert(std.math.isPowerOfTwo(size));

        if (base_type.is_float()) assert(!base_type.is_signed());
        if (base_type.is_signed()) assert(!base_type.is_float());

        if (base_type.invalid_value()) |sentinel| {
            const width_bits = @as(u16, size) * 8;

            assert(width_bits >= 8);
            assert(width_bits <= element_bytes_max * 8);

            if (width_bits < element_bytes_max * 8) assert(sentinel >> @intCast(width_bits) == 0);
        } else {
            assert(base_type == .string);
        }
    }
}

test BaseType {
    try std.testing.expectEqual(@as(u8, 4), BaseType.uint32.size_bytes());
    try std.testing.expectEqual(@as(?u64, 0xFFFF), BaseType.uint16.invalid_value());
    try std.testing.expectEqual(@as(?u64, 0), BaseType.uint32z.invalid_value());
    try std.testing.expect(BaseType.string.invalid_value() == null);
    try std.testing.expect(BaseType.sint16.is_signed());
    try std.testing.expect(!BaseType.uint16.is_signed());
    try std.testing.expect(BaseType.float64.is_float());
    try std.testing.expect(!BaseType.uint64.is_float());
}

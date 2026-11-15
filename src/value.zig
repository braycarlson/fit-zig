const std = @import("std");

const base_type_module = @import("base_type.zig");
const parser_module = @import("parser.zig");
const profile = @import("profile.zig");

const Endian = std.lang.Endian;
const assert = std.debug.assert;

const BaseType = base_type_module.BaseType;
const DataMessage = Parser.DataMessage;
const Parser = parser_module.Parser;
const RawField = Parser.Field;

pub const Value = union(enum) {
    none,
    integer: i64,
    unsigned: u64,
    real: f64,
    string: []const u8,
    enumeration: []const u8,
    bytes: []const u8,
    integer_array: Array,
    real_array: Array,

    pub const Array = struct {
        architecture: Endian,
        base_type: BaseType,
        bytes: []const u8,
        offset: f64,
        scale: f64,

        pub fn count(array: *const Array) u32 {
            assert(array.bytes.len <= parser_module.field_bytes_max);
            assert(array.base_type != .string);

            const result: u32 = @intCast(@divFloor(array.bytes.len, array.base_type.size_bytes()));

            assert(result * array.base_type.size_bytes() <= array.bytes.len);

            return result;
        }

        pub fn integer_of(array: *const Array, index: u32) i64 {
            assert(index < array.count());
            assert(array.scale == 1.0);

            const result: i64 = switch (array.element_of(index)) {
                .integer => |number| number,
                .unsigned => |number| std.math.cast(i64, number) orelse 0,
                .none, .real, .string, .enumeration, .bytes => 0,
                .integer_array, .real_array => unreachable,
            };

            return result;
        }

        pub fn real_of(array: *const Array, index: u32) f64 {
            assert(index < array.count());
            assert(array.scale != 0.0);

            const result: f64 = switch (array.element_of(index)) {
                .real => |number| number,
                .integer => |number| @floatFromInt(number),
                .unsigned => |number| @floatFromInt(number),
                .none, .string, .enumeration, .bytes => std.math.nan(f64),
                .integer_array, .real_array => unreachable,
            };

            return result;
        }

        fn element_of(array: *const Array, index: u32) Value {
            assert(index < array.count());

            const element = array.base_type.size_bytes();
            const start = index * element;

            const field: RawField = .{
                .architecture = array.architecture,
                .base_type = array.base_type,
                .bytes = array.bytes[start..][0..element],
                .number = 0,
            };

            const meta: Meta = .{
                .name = "",
                .offset = array.offset,
                .scale = array.scale,
                .type_index = null,
                .type_name = "",
                .units = "",
            };

            const result = decode(&field, &meta);

            assert(result != .integer_array);
            assert(result != .real_array);

            return result;
        }
    };
};

const Scalar = struct {
    base: BaseType,
    raw: u64,
};

pub const Meta = struct {
    name: []const u8,
    offset: f64,
    scale: f64,
    type_index: ?u16,
    type_name: []const u8,
    units: []const u8,
};

pub const bits_max: u32 = @bitSizeOf(u64);
pub const bytes_max: u32 = @divExact(bits_max, 8);

pub const plain: Meta = .{
    .name = "",
    .offset = 0.0,
    .scale = 1.0,
    .type_index = null,
    .type_name = "",
    .units = "",
};

comptime {
    assert(bytes_max == 8);
    assert(bytes_max == BaseType.uint64.size_bytes());
}

pub fn meta_of(message: *const DataMessage, field: *const profile.Field) Meta {
    assert(field.name.len > 0);
    assert(field.scale != 0.0);

    for (field.subfields) |*subfield| {
        if (reference_matches(message, subfield)) {
            return .{
                .name = subfield.name,
                .offset = subfield.offset,
                .scale = subfield.scale,
                .type_index = subfield.type_index,
                .type_name = subfield.type_name,
                .units = subfield.units,
            };
        }
    }

    return .{
        .name = field.name,
        .offset = field.offset,
        .scale = field.scale,
        .type_index = field.type_index,
        .type_name = field.type_name,
        .units = field.units,
    };
}

pub fn decode(field: *const RawField, meta: *const Meta) Value {
    assert(meta.scale != 0.0);
    assert(field.bytes.len <= parser_module.field_bytes_max);

    const base = field.base_type;

    if (field.bytes.len == 0) return .none;
    if (base == .string) return decode_string(field.bytes);
    if (field.bytes.len != base.size_bytes()) return .{ .bytes = field.bytes };

    const scalar: Scalar = .{ .base = base, .raw = read_unsigned(field) };

    if (is_invalid(&scalar)) return .none;

    if (base.is_float()) {
        const number = read_float(&scalar);

        if (is_scaled(meta)) return .{ .real = number / meta.scale - meta.offset };
        return .{ .real = number };
    }

    if (meta.type_index) |type_index| {
        const key: profile.TypeValueKey = .{ .type_index = type_index, .value = scalar.raw };

        if (profile.type_value_name(&key)) |name| return .{ .enumeration = name };
    }

    const number: f64 = if (base.is_signed())
        @floatFromInt(sign_extend(&scalar))
    else
        @floatFromInt(scalar.raw);

    if (is_scaled(meta)) return .{ .real = number / meta.scale - meta.offset };
    if (base.is_signed()) return .{ .integer = sign_extend(&scalar) };
    return .{ .unsigned = scalar.raw };
}

pub fn low_bits_mask(bits: u7) u64 {
    assert(bits >= 1);
    assert(bits <= bits_max);

    const result = ~@as(u64, 0) >> @intCast(bits_max - @as(u32, bits));

    assert(result >= 1);
    assert(@popCount(result) == bits);

    return result;
}

pub fn c_string(bytes: []const u8) []const u8 {
    assert(bytes.len <= parser_module.field_bytes_max);

    const end = std.mem.findScalar(u8, bytes, 0) orelse bytes.len;
    const result = bytes[0..end];

    assert(std.mem.findScalar(u8, result, 0) == null);

    return result;
}

pub fn field_unsigned(field: *const RawField) ?u64 {
    assert(field.bytes.len <= parser_module.field_bytes_max);

    const element = field.base_type.size_bytes();

    assert(element >= 1);

    if (field.bytes.len != element) return null;
    return read_unsigned(field);
}

pub fn raw_bits(field: *const RawField) ?u64 {
    assert(field.bytes.len <= parser_module.field_bytes_max);

    if (field.bytes.len == 0) return null;
    if (field.bytes.len > bytes_max) return null;

    const result = read_unsigned(field);

    if (field.bytes.len < bytes_max) assert(result >> @intCast(field.bytes.len * 8) == 0);

    return result;
}

fn is_scaled(meta: *const Meta) bool {
    assert(meta.scale != 0.0);
    assert(std.math.isFinite(meta.scale));

    if (meta.scale != 1.0) return true;
    return meta.offset != 0.0;
}

fn reference_matches(message: *const DataMessage, subfield: *const profile.Subfield) bool {
    assert(subfield.reference_value >= 0);
    assert(message.payload.len == message.definition.payload_size_bytes);

    var fields = message.fields();

    for (0..parser_module.field_count_max) |_| {
        const field = fields.next() orelse break;
        if (field.number != subfield.reference_field_number) continue;

        const raw = field_unsigned(&field) orelse return false;
        return raw == @as(u64, @intCast(subfield.reference_value));
    }

    return false;
}

fn read_unsigned(field: *const RawField) u64 {
    assert(field.bytes.len >= 1);
    assert(field.bytes.len <= bytes_max);

    const result = std.mem.readVarInt(u64, field.bytes, field.architecture);

    if (field.bytes.len < bytes_max) assert(result >> @intCast(field.bytes.len * 8) == 0);

    return result;
}

fn read_float(scalar: *const Scalar) f64 {
    assert(scalar.base.is_float());

    return switch (scalar.base) {
        .float32 => @as(f32, @bitCast(@as(u32, @intCast(scalar.raw)))),
        .float64 => @bitCast(scalar.raw),
        .enum_value, .sint8, .uint8, .string, .uint8z, .byte => unreachable,
        .sint16, .uint16, .uint16z => unreachable,
        .sint32, .uint32, .uint32z => unreachable,
        .sint64, .uint64, .uint64z => unreachable,
    };
}

fn sign_extend(scalar: *const Scalar) i64 {
    assert(scalar.base.is_signed());

    const element = scalar.base.size_bytes();

    const result: i64 = switch (element) {
        1 => @as(i8, @bitCast(@as(u8, @intCast(scalar.raw)))),
        2 => @as(i16, @bitCast(@as(u16, @intCast(scalar.raw)))),
        4 => @as(i32, @bitCast(@as(u32, @intCast(scalar.raw)))),
        8 => @bitCast(scalar.raw),
        else => unreachable,
    };

    if (element < bytes_max) {
        const mask = low_bits_mask(@intCast(element * 8));

        assert(@as(u64, @bitCast(result)) & mask == scalar.raw);
    }

    return result;
}

fn is_invalid(scalar: *const Scalar) bool {
    assert(scalar.base != .string);

    const sentinel = scalar.base.invalid_value() orelse unreachable;
    const element = scalar.base.size_bytes();

    if (element < bytes_max) assert(sentinel >> @intCast(element * 8) == 0);

    return scalar.raw == sentinel;
}

fn decode_string(bytes: []const u8) Value {
    assert(bytes.len >= 1);
    assert(bytes.len <= parser_module.field_bytes_max);

    const text = c_string(bytes);
    if (text.len == 0) return .none;

    return .{ .string = text };
}

fn raw_field(base_type: BaseType, bytes: []const u8) RawField {
    assert(bytes.len <= parser_module.field_bytes_max);
    assert(base_type.size_bytes() >= 1);

    return .{ .architecture = .little, .base_type = base_type, .bytes = bytes, .number = 0 };
}

test decode {
    const value = decode(&raw_field(.uint8, &.{150}), &plain);

    try std.testing.expectEqual(@as(u64, 150), value.unsigned);
}

test "decode reports invalid sentinels as none" {
    const invalid = decode(&raw_field(.uint8, &.{0xFF}), &plain);
    const zero = decode(&raw_field(.uint16z, &.{ 0, 0 }), &plain);

    try std.testing.expect(invalid == .none);
    try std.testing.expect(zero == .none);
}

test "decode applies scale and offset" {
    const meta: Meta = .{
        .name = "speed",
        .offset = 0.0,
        .scale = 1000.0,
        .type_index = null,
        .type_name = "uint16",
        .units = "m/s",
    };

    const value = decode(&raw_field(.uint16, &.{ 0xE8, 0x03 }), &meta);

    try std.testing.expectApproxEqAbs(@as(f64, 1.0), value.real, 1e-9);
}

test "decode resolves enum names" {
    const meta: Meta = .{
        .name = "type",
        .offset = 0.0,
        .scale = 1.0,
        .type_index = profile.type_find("file"),
        .type_name = "file",
        .units = "",
    };

    const value = decode(&raw_field(.enum_value, &.{4}), &meta);

    try std.testing.expectEqualStrings("activity", value.enumeration);
}

test "decode sign-extends signed fields" {
    const value = decode(&raw_field(.sint8, &.{0xFF}), &plain);

    try std.testing.expectEqual(@as(i64, -1), value.integer);

    const negative = decode(&raw_field(.sint16, &.{ 0xFE, 0xFF }), &plain);
    const invalid = decode(&raw_field(.sint8, &.{0x7F}), &plain);

    try std.testing.expectEqual(@as(i64, -2), negative.integer);
    try std.testing.expect(invalid == .none);
}

test low_bits_mask {
    try std.testing.expectEqual(@as(u64, 0x1), low_bits_mask(1));
    try std.testing.expectEqual(@as(u64, 0xFF), low_bits_mask(8));
    try std.testing.expectEqual(@as(u64, 0xFFFFFFFF), low_bits_mask(32));
    try std.testing.expectEqual(~@as(u64, 0), low_bits_mask(64));
}

test c_string {
    try std.testing.expectEqualStrings("ab", c_string(&.{ 'a', 'b', 0, 'c' }));
    try std.testing.expectEqualStrings("abc", c_string(&.{ 'a', 'b', 'c' }));
    try std.testing.expectEqualStrings("", c_string(&.{0}));
    try std.testing.expectEqualStrings("", c_string(&.{}));
}

test "an array reads each element on demand with its scaling" {
    const unscaled: Value.Array = .{
        .architecture = .little,
        .base_type = .sint16,
        .bytes = &.{ 0x0A, 0x00, 0xFE, 0xFF, 0xFF, 0x7F },
        .offset = 0.0,
        .scale = 1.0,
    };

    try std.testing.expectEqual(@as(u32, 3), unscaled.count());
    try std.testing.expectEqual(@as(i64, 10), unscaled.integer_of(0));
    try std.testing.expectEqual(@as(i64, -2), unscaled.integer_of(1));
    try std.testing.expectEqual(@as(i64, 0), unscaled.integer_of(2));

    const scaled: Value.Array = .{
        .architecture = .big,
        .base_type = .uint16,
        .bytes = &.{ 0x03, 0xE8, 0xFF, 0xFF },
        .offset = 0.0,
        .scale = 1000.0,
    };

    try std.testing.expectEqual(@as(u32, 2), scaled.count());
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), scaled.real_of(0), 1e-12);
    try std.testing.expect(std.math.isNan(scaled.real_of(1)));
}

const std = @import("std");

const base_type_module = @import("base_type.zig");
const crc = @import("crc.zig");
const parser_module = @import("parser.zig");

const assert = std.debug.assert;

const BaseType = base_type_module.BaseType;
const Parser = parser_module.Parser;
const RecordHeader = parser_module.RecordHeader;

pub const Encoder = struct {
    buffer: []u8,
    clock: u4,
    count: u32,
    slots: [parser_module.local_type_count]?u64,

    pub const CapacityError = error{BufferExhausted};
    pub const Error = CapacityError || ValueError;

    pub const ValueError = error{
        FieldCountExceeded,
        StringTooLong,
    };

    pub const Field = struct {
        number: u8,
        value: Value,
    };

    pub const Message = struct {
        fields: []const Field,
        global_number: u16,
    };

    pub const Value = union(enum) {
        enum_value: u8,
        uint8: u8,
        uint16: u16,
        uint32: u32,
        sint8: i8,
        sint16: i16,
        sint32: i32,
        float32: f32,
        float64: f64,
        string: []const u8,

        fn base_type(value: *const Value) BaseType {
            const result: BaseType = switch (value.*) {
                .enum_value => .enum_value,
                .uint8 => .uint8,
                .uint16 => .uint16,
                .uint32 => .uint32,
                .sint8 => .sint8,
                .sint16 => .sint16,
                .sint32 => .sint32,
                .float32 => .float32,
                .float64 => .float64,
                .string => .string,
            };

            if (value.* != .string) assert(result.size_bytes() == value.size_bytes());

            return result;
        }

        fn size_bytes(value: *const Value) u8 {
            const result: u8 = switch (value.*) {
                .enum_value, .uint8, .sint8 => 1,
                .uint16, .sint16 => 2,
                .uint32, .sint32, .float32 => 4,
                .float64 => 8,
                .string => |text| @intCast(text.len + 1),
            };

            assert(result >= 1);
            assert(result <= parser_module.field_bytes_max);

            return result;
        }

        fn write(value: *const Value, target: []u8) void {
            assert(target.len == value.size_bytes());

            switch (value.*) {
                .enum_value, .uint8 => |number| target[0] = number,
                .sint8 => |number| target[0] = @bitCast(number),
                .uint16 => |number| std.mem.writeInt(u16, target[0..2], number, .little),
                .sint16 => |number| std.mem.writeInt(i16, target[0..2], number, .little),
                .uint32 => |number| std.mem.writeInt(u32, target[0..4], number, .little),
                .sint32 => |number| std.mem.writeInt(i32, target[0..4], number, .little),
                .float32 => |number| std.mem.writeInt(u32, target[0..4], @bitCast(number), .little),
                .float64 => |number| std.mem.writeInt(u64, target[0..8], @bitCast(number), .little),
                .string => |text| {
                    @memcpy(target[0..text.len], text);
                    target[text.len] = 0;
                },
            }
        }
    };

    pub fn init(encoder: *Encoder, buffer: []u8) void {
        assert(buffer.len >= header_bytes + crc.checksum_bytes);
        assert(buffer.len <= parser_module.source_bytes_max);

        encoder.buffer = buffer;
        encoder.clock = 0;
        encoder.count = header_bytes;
        encoder.slots = @splat(null);

        assert(encoder.count < encoder.buffer.len);
    }

    pub fn write_message(encoder: *Encoder, message: *const Message) Error!void {
        assert(encoder.count >= header_bytes);
        assert(encoder.count <= encoder.buffer.len);

        const fields = message.fields;

        if (fields.len > parser_module.field_count_max) return error.FieldCountExceeded;

        for (fields) |*field| {
            if (field.value == .string) {
                if (field.value.string.len > string_bytes_max) return error.StringTooLong;
            }
        }

        const fingerprint = fingerprint_of(message);
        const local = encoder.slot_find(fingerprint);
        const definition_bytes: u32 = if (local == null) definition_size_bytes(fields) else 0;
        const data_bytes = data_size_bytes(fields);
        const available = encoder.buffer.len - crc.checksum_bytes - encoder.count;

        if (definition_bytes + data_bytes > available) return error.BufferExhausted;

        const before = encoder.count;
        const slot = local orelse encoder.slot_claim(fingerprint);

        if (local == null) encoder.definition_write(slot, message);

        encoder.data_write(slot, fields);

        assert(encoder.count == before + definition_bytes + data_bytes);
        assert(encoder.slot_find(fingerprint).? == slot);
    }

    pub fn close(encoder: *Encoder) []const u8 {
        assert(encoder.count >= header_bytes);
        assert(encoder.count + crc.checksum_bytes <= encoder.buffer.len);

        const header = encoder.buffer[0..header_bytes];
        const signature_end = parser_module.signature_offset + parser_module.signature_bytes;

        header[0] = header_bytes;
        header[1] = protocol_version;

        std.mem.writeInt(u16, header[2..4], profile_version, .little);
        std.mem.writeInt(u32, header[4..8], encoder.count - header_bytes, .little);
        const signature = header[parser_module.signature_offset..signature_end];

        @memcpy(signature, parser_module.file_signature);

        const checksum = crc.checksum(encoder.buffer[0..encoder.count]);
        const trailer = encoder.buffer[encoder.count..][0..crc.checksum_bytes];

        std.mem.writeInt(u16, trailer, checksum, .little);

        const result = encoder.buffer[0 .. encoder.count + crc.checksum_bytes];

        assert(std.mem.readInt(u32, header[4..8], .little) == encoder.count - header_bytes);
        assert(result.len >= header_bytes + crc.checksum_bytes);

        return result;
    }

    fn slot_find(encoder: *const Encoder, fingerprint: u64) ?u4 {
        assert(encoder.slots.len == parser_module.local_type_count);

        for (encoder.slots, 0..) |slot, index| {
            const cached = slot orelse continue;
            if (cached == fingerprint) return @intCast(index);
        }

        return null;
    }

    fn slot_claim(encoder: *Encoder, fingerprint: u64) u4 {
        assert(encoder.slot_find(fingerprint) == null);

        const result = encoder.clock;

        encoder.clock +%= 1;
        encoder.slots[result] = fingerprint;

        assert(encoder.slots[result].? == fingerprint);

        return result;
    }

    fn definition_write(encoder: *Encoder, local: u4, message: *const Message) void {
        assert(message.fields.len <= parser_module.field_count_max);
        assert(encoder.slots[local] != null);

        const record: RecordHeader = .{
            .local_message_type = local,
            .reserved = 0,
            .developer_data = 0,
            .message_kind = .definition,
            .header_kind = .normal,
        };

        const fixed = [definition_fixed_bytes]u8{
            @bitCast(record),
            0,
            architecture_little_endian,
            @truncate(message.global_number),
            @truncate(message.global_number >> 8),
            @intCast(message.fields.len),
        };

        const before = encoder.count;

        encoder.slice_write(&fixed);

        for (message.fields) |*field| {
            encoder.slice_write(&.{
                field.number,
                field.value.size_bytes(),
                @backingInt(field.value.base_type()),
            });
        }

        assert(encoder.count == before + definition_size_bytes(message.fields));
    }

    fn data_write(encoder: *Encoder, local: u4, fields: []const Field) void {
        assert(fields.len <= parser_module.field_count_max);
        assert(encoder.slots[local] != null);

        const before = encoder.count;

        const record: RecordHeader = .{
            .local_message_type = local,
            .reserved = 0,
            .developer_data = 0,
            .message_kind = .data,
            .header_kind = .normal,
        };

        encoder.byte_write(@bitCast(record));

        for (fields) |*field| {
            const size = field.value.size_bytes();

            field.value.write(encoder.buffer[encoder.count..][0..size]);
            encoder.count += size;
        }

        assert(encoder.count == before + data_size_bytes(fields));
    }

    fn slice_write(encoder: *Encoder, bytes: []const u8) void {
        assert(bytes.len <= definition_fixed_bytes);
        assert(encoder.count + bytes.len + crc.checksum_bytes <= encoder.buffer.len);

        @memcpy(encoder.buffer[encoder.count..][0..bytes.len], bytes);
        encoder.count += @intCast(bytes.len);
    }

    fn byte_write(encoder: *Encoder, byte: u8) void {
        assert(encoder.count + crc.checksum_bytes < encoder.buffer.len);

        encoder.buffer[encoder.count] = byte;
        encoder.count += 1;

        assert(encoder.buffer[encoder.count - 1] == byte);
    }
};

pub const string_bytes_max: u32 = parser_module.field_bytes_max - 1;

const architecture_little_endian: u8 = 0;
const definition_fixed_bytes: u32 = 6;
const header_bytes: u8 = parser_module.header_bytes_min;
const profile_version: u16 = 0;
const protocol_version: u8 = 0x20;

comptime {
    assert(protocol_version >> 4 == 2);
    assert(definition_fixed_bytes == 1 + 1 + 1 + 2 + 1);
    assert(string_bytes_max == 254);
}

fn definition_size_bytes(fields: []const Encoder.Field) u32 {
    assert(fields.len <= parser_module.field_count_max);

    const result: u32 = definition_fixed_bytes + 3 * @as(u32, @intCast(fields.len));

    assert(result >= definition_fixed_bytes);

    return result;
}

fn data_size_bytes(fields: []const Encoder.Field) u32 {
    assert(fields.len <= parser_module.field_count_max);

    var result: u32 = 1;

    for (fields) |*field| result += field.value.size_bytes();

    assert(result <= 1 + parser_module.field_count_max * parser_module.field_bytes_max);

    return result;
}

fn fingerprint_of(message: *const Encoder.Message) u64 {
    assert(message.fields.len <= parser_module.field_count_max);

    var hasher = std.hash.Wyhash.init(message.global_number);

    for (message.fields) |*field| {
        const layout = [_]u8{
            field.number,
            field.value.size_bytes(),
            @backingInt(field.value.base_type()),
        };

        hasher.update(&layout);
    }

    return hasher.final();
}

test Encoder {
    var buffer: [256]u8 = undefined;
    var encoder: Encoder = undefined;

    encoder.init(&buffer);

    try encoder.write_message(&.{
        .fields = &.{
            .{ .number = 0, .value = .{ .enum_value = 4 } },
            .{ .number = 1, .value = .{ .uint16 = 1 } },
            .{ .number = 3, .value = .{ .uint32 = 12345 } },
        },
        .global_number = 0,
    });

    try encoder.write_message(&.{
        .fields = &.{
            .{ .number = 253, .value = .{ .uint32 = 1_000_000_000 } },
            .{ .number = 3, .value = .{ .uint8 = 75 } },
        },
        .global_number = 20,
    });

    const bytes = encoder.close();

    try parser_module.verify_checksum(bytes);

    var parser: Parser = undefined;

    try parser.init(bytes);

    const file_id = (try parser.next()).message;

    try std.testing.expectEqual(@as(u16, 0), file_id.global_number);

    var file_id_fields = file_id.fields();

    const file_type = file_id_fields.next() orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(@as(u8, 4), file_type.bytes[0]);

    const record = (try parser.next()).message;

    try std.testing.expectEqual(@as(u16, 20), record.global_number);
    try std.testing.expectEqual(@as(?u32, 1_000_000_000), record.timestamp);
    const trailing = try parser.next();

    try std.testing.expect(trailing == .end);
}

test "a repeated message layout reuses one definition" {
    var buffer: [64]u8 = undefined;
    var encoder: Encoder = undefined;

    encoder.init(&buffer);

    const message: Encoder.Message = .{
        .fields = &.{.{ .number = 3, .value = .{ .uint8 = 60 } }},
        .global_number = 20,
    };

    try encoder.write_message(&message);

    const after_first = encoder.count;

    try encoder.write_message(&message);

    try std.testing.expectEqual(@as(u32, 2), encoder.count - after_first);
}

test "the encoder refuses a string longer than a field size can express" {
    var buffer: [1024]u8 = undefined;
    var encoder: Encoder = undefined;

    encoder.init(&buffer);

    const too_long: [string_bytes_max + 1]u8 = @splat('x');

    const message: Encoder.Message = .{
        .fields = &.{.{ .number = 3, .value = .{ .string = &too_long } }},
        .global_number = 20,
    };

    try std.testing.expectError(error.StringTooLong, encoder.write_message(&message));
    try std.testing.expectEqual(@as(u32, header_bytes), encoder.count);
}

test "the encoder accepts a string that exactly fills a field" {
    var buffer: [1024]u8 = undefined;
    var encoder: Encoder = undefined;

    encoder.init(&buffer);

    const longest: [string_bytes_max]u8 = @splat('x');

    try encoder.write_message(&.{
        .fields = &.{.{ .number = 3, .value = .{ .string = &longest } }},
        .global_number = 20,
    });

    try parser_module.verify_checksum(encoder.close());
}

test "the encoder refuses more fields than a definition can declare" {
    var buffer: [64]u8 = undefined;
    var encoder: Encoder = undefined;

    encoder.init(&buffer);

    const fields: [256]Encoder.Field = @splat(.{ .number = 3, .value = .{ .uint8 = 1 } });
    const message: Encoder.Message = .{ .fields = &fields, .global_number = 20 };

    try std.testing.expectError(error.FieldCountExceeded, encoder.write_message(&message));
}

test "the encoder refuses a message that does not fit and leaves the buffer intact" {
    var buffer: [25]u8 = undefined;
    var encoder: Encoder = undefined;

    encoder.init(&buffer);

    const fields = [_]Encoder.Field{.{ .number = 3, .value = .{ .uint8 = 1 } }};

    try encoder.write_message(&.{ .fields = &fields, .global_number = 20 });

    const before = encoder.count;
    const refused = encoder.write_message(&.{ .fields = &fields, .global_number = 21 });

    try std.testing.expectError(error.BufferExhausted, refused);
    try std.testing.expectEqual(before, encoder.count);
    try parser_module.verify_checksum(encoder.close());
}

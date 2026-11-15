const std = @import("std");

const base_type_module = @import("base_type.zig");
const crc = @import("crc.zig");

const Endian = std.lang.Endian;
const assert = std.debug.assert;

const BaseType = base_type_module.BaseType;

pub const Parser = struct {
    bytes: []const u8,
    cursor: u32,
    data_end: u32,
    definition_sequence: u32,
    definitions: [local_type_count]?MessageDefinition,
    diagnostic: Diagnostic,
    header: Header,
    timestamp: ?u32,

    pub const CapacityError = error{ChainedFileCountExceeded};
    pub const Error = CapacityError || SyntaxError;

    pub const SyntaxError = error{
        BaseTypeUnknown,
        HeaderSizeInvalid,
        LocalTypeUndefined,
        SignatureInvalid,
        Truncated,
    };

    pub const DataMessage = struct {
        architecture: Endian,
        definition: *const MessageDefinition,
        global_number: u16,
        local_type: u4,
        offset: u32,
        payload: []const u8,
        timestamp: ?u32,

        pub fn fields(message: *const DataMessage) Fields {
            assert(message.definition.payload_size_bytes == message.payload.len);
            assert(message.definition.regular_size_bytes <= message.payload.len);

            return .{
                .definition = message.definition,
                .index = 0,
                .offset = 0,
                .payload = message.payload,
                .remaining = message.definition.field_count,
            };
        }

        pub fn developer_fields(message: *const DataMessage) DeveloperFields {
            assert(message.definition.payload_size_bytes == message.payload.len);
            assert(message.definition.regular_size_bytes <= message.payload.len);

            return .{
                .definition = message.definition,
                .index = 0,
                .offset = message.definition.regular_size_bytes,
                .payload = message.payload,
                .remaining = message.definition.developer_field_count,
            };
        }
    };

    pub const DeveloperField = struct {
        architecture: Endian,
        bytes: []const u8,
        developer_data_index: u8,
        number: u8,
    };

    pub const DeveloperFieldDefinition = struct {
        developer_data_index: u8,
        number: u8,
        size_bytes: u8,
    };

    pub const DeveloperFields = struct {
        definition: *const MessageDefinition,
        index: u8,
        offset: u32,
        payload: []const u8,
        remaining: u8,

        pub fn next(iterator: *DeveloperFields) ?DeveloperField {
            assert(iterator.remaining <= iterator.definition.developer_field_count);
            assert(iterator.offset >= iterator.definition.regular_size_bytes);

            if (iterator.remaining == 0) return null;

            const definition = iterator.definition.developer_fields[iterator.index];
            const start = iterator.offset;
            const end = start + definition.size_bytes;

            assert(end <= iterator.payload.len);

            iterator.index += 1;
            iterator.offset = end;
            iterator.remaining -= 1;

            return .{
                .architecture = iterator.definition.architecture,
                .bytes = iterator.payload[start..end],
                .developer_data_index = definition.developer_data_index,
                .number = definition.number,
            };
        }
    };

    pub const Field = struct {
        architecture: Endian,
        base_type: BaseType,
        bytes: []const u8,
        number: u8,
    };

    pub const FieldDefinition = struct {
        base_type: BaseType,
        number: u8,
        size_bytes: u8,
    };

    pub const Fields = struct {
        definition: *const MessageDefinition,
        index: u8,
        offset: u32,
        payload: []const u8,
        remaining: u8,

        pub fn next(iterator: *Fields) ?Field {
            assert(iterator.remaining <= iterator.definition.field_count);
            assert(iterator.offset <= iterator.definition.regular_size_bytes);

            if (iterator.remaining == 0) return null;

            const definition = iterator.definition.fields[iterator.index];
            const start = iterator.offset;
            const end = start + definition.size_bytes;

            assert(end <= iterator.definition.regular_size_bytes);

            iterator.index += 1;
            iterator.offset = end;
            iterator.remaining -= 1;

            return .{
                .architecture = iterator.definition.architecture,
                .base_type = definition.base_type,
                .bytes = iterator.payload[start..end],
                .number = definition.number,
            };
        }
    };

    pub const Header = struct {
        crc: u16,
        data_size_bytes: u32,
        profile_version: u16,
        protocol_version: u8,
        size_bytes: u8,
    };

    pub const MessageDefinition = struct {
        architecture: Endian,
        developer_field_count: u8,
        developer_fields: [field_count_max]DeveloperFieldDefinition,
        field_count: u8,
        fields: [field_count_max]FieldDefinition,
        global_number: u16,
        payload_size_bytes: u32,
        regular_size_bytes: u32,
        sequence: u32,
        timestamp_offset: ?u16,
    };

    pub const Next = union(enum) {
        end,
        message: DataMessage,
    };

    const Record = union(enum) {
        definition,
        message: DataMessage,
    };

    pub fn init(parser: *Parser, bytes: []const u8) SyntaxError!void {
        assert(bytes.len <= source_bytes_max);

        parser.bytes = bytes;
        parser.cursor = 0;
        parser.data_end = 0;
        parser.definition_sequence = 0;
        parser.diagnostic = .{ .offset = 0 };
        parser.timestamp = null;

        try parser.file_open(0);

        assert(parser.cursor == parser.header.size_bytes);
        assert(parser.data_end <= parser.bytes.len);
    }

    pub fn next(parser: *Parser) Error!Next {
        assert(parser.cursor <= parser.data_end);
        assert(parser.data_end <= parser.bytes.len);

        var file_count: u32 = 0;

        for (0..parser.bytes.len + 1) |_| {
            if (parser.cursor == parser.data_end) {
                if (file_count == chained_file_count_max) return error.ChainedFileCountExceeded;
                if (!parser.file_advance()) return .end;

                file_count += 1;

                continue;
            }

            const offset = parser.cursor;

            const record = parser.record_read() catch |err| {
                parser.diagnostic = .{ .offset = offset };

                return err;
            };

            assert(parser.cursor > offset);

            switch (record) {
                .definition => {},
                .message => |message| return .{ .message = message },
            }
        }

        unreachable;
    }

    fn file_open(parser: *Parser, start: u32) SyntaxError!void {
        assert(start <= parser.bytes.len);

        const header = try header_parse(parser.bytes[start..]);
        const data_start = start + header.size_bytes;
        const available: u32 = @intCast(parser.bytes.len - data_start);

        if (header.data_size_bytes > available) return error.Truncated;

        parser.header = header;
        parser.cursor = data_start;
        parser.data_end = data_start + header.data_size_bytes;
        parser.definitions = @splat(null);
        parser.timestamp = null;

        assert(parser.cursor <= parser.data_end);
        assert(parser.data_end <= parser.bytes.len);
    }

    fn file_advance(parser: *Parser) bool {
        assert(parser.cursor == parser.data_end);
        assert(parser.data_end <= parser.bytes.len);

        const remaining: u32 = @intCast(parser.bytes.len - parser.cursor);
        if (remaining < crc.checksum_bytes + header_bytes_min) return false;

        parser.file_open(parser.cursor + crc.checksum_bytes) catch return false;

        return true;
    }

    fn record_read(parser: *Parser) SyntaxError!Record {
        assert(parser.cursor < parser.data_end);
        assert(parser.data_end <= parser.bytes.len);

        const offset = parser.cursor;
        const first = try parser.byte_take();
        const record: RecordHeader = @bitCast(first);

        switch (record.header_kind) {
            .compressed => {
                const compressed: CompressedTimestampHeader = @bitCast(first);

                return .{ .message = try parser.data_message_read(&.{
                    .compressed_offset = compressed.time_offset,
                    .local_type = compressed.local_message_type,
                    .offset = offset,
                }) };
            },
            .normal => switch (record.message_kind) {
                .definition => {
                    try parser.definition_read(record);

                    return .definition;
                },
                .data => return .{ .message = try parser.data_message_read(&.{
                    .compressed_offset = null,
                    .local_type = record.local_message_type,
                    .offset = offset,
                }) },
            },
        }
    }

    fn definition_read(parser: *Parser, record: RecordHeader) SyntaxError!void {
        assert(record.header_kind == .normal);
        assert(record.message_kind == .definition);

        _ = try parser.byte_take();

        const architecture: Endian = if ((try parser.byte_take()) == 0) .little else .big;
        const global_bytes = try parser.slice_take(2);
        const global_number = std.mem.readInt(u16, global_bytes[0..2], architecture);
        const field_count = try parser.byte_take();

        parser.definition_sequence += 1;

        const slot = &parser.definitions[record.local_message_type];

        slot.* = .{
            .architecture = architecture,
            .developer_field_count = 0,
            .developer_fields = undefined,
            .field_count = field_count,
            .fields = undefined,
            .global_number = global_number,
            .payload_size_bytes = 0,
            .regular_size_bytes = 0,
            .sequence = parser.definition_sequence,
            .timestamp_offset = null,
        };

        errdefer slot.* = null;

        const definition = &slot.*.?;

        definition.regular_size_bytes = try parser.field_definitions_read(definition);
        definition.payload_size_bytes = definition.regular_size_bytes;

        if (record.developer_data == 1) {
            definition.payload_size_bytes += try parser.developer_definitions_read(definition);
        }

        assert(definition.payload_size_bytes >= definition.regular_size_bytes);
        assert(definition.payload_size_bytes <= payload_bytes_max);
    }

    fn field_definitions_read(parser: *Parser, definition: *MessageDefinition) SyntaxError!u32 {
        assert(definition.field_count <= field_count_max);
        assert(definition.timestamp_offset == null);

        var payload_size: u32 = 0;

        for (0..definition.field_count) |index| {
            const number = try parser.byte_take();
            const size_bytes = try parser.byte_take();
            const base_type_raw = try parser.byte_take();

            const base_type = std.enums.fromInt(BaseType, base_type_raw) orelse
                return error.BaseTypeUnknown;

            if (number == timestamp_field_number) {
                if (size_bytes == timestamp_bytes) {
                    definition.timestamp_offset = @intCast(payload_size);
                }
            }

            definition.fields[index] = .{
                .base_type = base_type,
                .number = number,
                .size_bytes = size_bytes,
            };

            payload_size += size_bytes;
        }

        assert(payload_size <= field_count_max * field_bytes_max);

        if (definition.timestamp_offset) |offset| assert(offset + timestamp_bytes <= payload_size);

        return payload_size;
    }

    fn developer_definitions_read(
        parser: *Parser,
        definition: *MessageDefinition,
    ) SyntaxError!u32 {
        assert(definition.developer_field_count == 0);
        assert(definition.regular_size_bytes <= payload_bytes_max);

        const count = try parser.byte_take();

        var size_total: u32 = 0;

        for (0..count) |index| {
            const number = try parser.byte_take();
            const size_bytes = try parser.byte_take();
            const developer_data_index = try parser.byte_take();

            definition.developer_fields[index] = .{
                .developer_data_index = developer_data_index,
                .number = number,
                .size_bytes = size_bytes,
            };

            size_total += size_bytes;
        }

        definition.developer_field_count = count;

        assert(size_total <= field_count_max * field_bytes_max);

        return size_total;
    }

    fn data_message_read(parser: *Parser, record: *const DataRecord) SyntaxError!DataMessage {
        assert(record.offset < parser.cursor);
        assert(parser.cursor <= parser.data_end);

        const definition = if (parser.definitions[record.local_type]) |*found|
            found
        else
            return error.LocalTypeUndefined;

        const payload = try parser.slice_take(definition.payload_size_bytes);

        assert(payload.len == definition.payload_size_bytes);
        assert(payload.len >= definition.regular_size_bytes);

        return .{
            .architecture = definition.architecture,
            .definition = definition,
            .global_number = definition.global_number,
            .local_type = record.local_type,
            .offset = record.offset,
            .payload = payload,
            .timestamp = parser.message_timestamp(definition, payload, record),
        };
    }

    fn message_timestamp(
        parser: *Parser,
        definition: *const MessageDefinition,
        payload: []const u8,
        record: *const DataRecord,
    ) ?u32 {
        assert(payload.len == definition.payload_size_bytes);
        assert(record.offset < parser.cursor);

        if (record.compressed_offset != null) return parser.timestamp_reconstruct(record);

        const offset = definition.timestamp_offset orelse return null;
        const end = @as(u32, offset) + timestamp_bytes;

        assert(end <= definition.regular_size_bytes);

        const bytes = payload[offset..][0..timestamp_bytes];
        const raw = std.mem.readInt(u32, bytes, definition.architecture);
        if (raw == timestamp_invalid) return null;

        parser.timestamp = raw;

        assert(parser.timestamp.? != timestamp_invalid);

        return raw;
    }

    fn timestamp_reconstruct(parser: *Parser, record: *const DataRecord) ?u32 {
        assert(record.compressed_offset != null);
        assert(rollover_mask == std.math.maxInt(u5));

        const offset: u32 = record.compressed_offset orelse unreachable;
        const previous = parser.timestamp orelse return null;

        var result = (previous & ~rollover_mask) | offset;

        if (offset < (previous & rollover_mask)) result +%= rollover_seconds;

        parser.timestamp = result;

        assert(result & rollover_mask == offset);
        assert(result -% previous < rollover_seconds);

        return result;
    }

    fn byte_take(parser: *Parser) SyntaxError!u8 {
        assert(parser.cursor <= parser.data_end);

        if (parser.cursor == parser.data_end) return error.Truncated;

        const result = parser.bytes[parser.cursor];

        parser.cursor += 1;

        assert(parser.cursor <= parser.data_end);

        return result;
    }

    fn slice_take(parser: *Parser, count: u32) SyntaxError![]const u8 {
        assert(count <= payload_bytes_max);
        assert(parser.cursor <= parser.data_end);

        if (count > parser.data_end - parser.cursor) return error.Truncated;

        const result = parser.bytes[parser.cursor..][0..count];

        parser.cursor += count;

        assert(parser.cursor <= parser.data_end);

        return result;
    }
};

const DataRecord = struct {
    compressed_offset: ?u5,
    local_type: u4,
    offset: u32,
};

pub const ChecksumError = error{
    ChecksumMismatch,
    Truncated,
};

pub const Diagnostic = struct {
    offset: u32,
};

pub const HeaderKind = enum(u1) {
    normal = 0,
    compressed = 1,
};

pub const MessageKind = enum(u1) {
    data = 0,
    definition = 1,
};

pub const RecordHeader = packed struct(u8) {
    local_message_type: u4,
    reserved: u1,
    developer_data: u1,
    message_kind: MessageKind,
    header_kind: HeaderKind,
};

pub const CompressedTimestampHeader = packed struct(u8) {
    time_offset: u5,
    local_message_type: u2,
    header_kind: HeaderKind,
};

pub const chained_file_count_max: u32 = 1024;
pub const developer_field_count_max: u32 = field_count_max;
pub const field_bytes_max: u32 = 255;
pub const field_count_max: u32 = 255;
pub const file_signature = ".FIT";
pub const header_bytes_max: u8 = 14;
pub const header_bytes_min: u8 = 12;
pub const local_type_count: u32 = 16;
pub const message_count_max: u32 = source_bytes_max;
pub const payload_bytes_max: u32 = 2 * field_count_max * field_bytes_max;
pub const signature_bytes: u32 = 4;
pub const signature_offset: u32 = 8;
pub const source_bytes_max: u32 = 1 << 30;
pub const timestamp_field_number: u8 = 253;

const rollover_mask: u32 = rollover_seconds - 1;
const rollover_seconds: u32 = 1 << @bitSizeOf(u5);
const timestamp_bytes: u32 = 4;
const timestamp_invalid: u32 = 0xFFFFFFFF;

comptime {
    assert(local_type_count == std.math.maxInt(u4) + 1);
    assert(field_count_max == std.math.maxInt(u8));
    assert(field_bytes_max == std.math.maxInt(u8));
    assert(header_bytes_max - header_bytes_min == crc.checksum_bytes);
    assert(signature_bytes == file_signature.len);
    assert(header_bytes_min == signature_offset + signature_bytes);
    assert(payload_bytes_max <= source_bytes_max);
    assert(source_bytes_max < std.math.maxInt(u32));
    assert(timestamp_bytes == BaseType.uint32.size_bytes());
    assert(timestamp_invalid == BaseType.uint32.invalid_value().?);
    assert(rollover_seconds == 32);
    assert(@bitSizeOf(RecordHeader) == 8);
    assert(@bitSizeOf(CompressedTimestampHeader) == 8);
}

pub fn verify_checksum(bytes: []const u8) ChecksumError!void {
    assert(bytes.len <= source_bytes_max);

    if (bytes.len < header_bytes_min + crc.checksum_bytes) return error.Truncated;

    const body = bytes[0 .. bytes.len - crc.checksum_bytes];
    const trailer = bytes[bytes.len - crc.checksum_bytes ..][0..crc.checksum_bytes];
    const expected = std.mem.readInt(u16, trailer, .little);
    const actual = crc.checksum(body);

    assert(body.len >= header_bytes_min);

    if (actual != expected) return error.ChecksumMismatch;
}

fn header_parse(bytes: []const u8) Parser.SyntaxError!Parser.Header {
    assert(bytes.len <= source_bytes_max);

    if (bytes.len == 0) return error.Truncated;

    const size_bytes = bytes[0];

    switch (size_bytes) {
        header_bytes_min, header_bytes_max => {},
        else => return error.HeaderSizeInvalid,
    }

    if (bytes.len < size_bytes) return error.Truncated;

    const signature = bytes[signature_offset..][0..signature_bytes];
    if (!std.mem.eql(u8, signature, file_signature)) return error.SignatureInvalid;

    const crc_present = size_bytes == header_bytes_max;

    const result: Parser.Header = .{
        .crc = if (crc_present) std.mem.readInt(u16, bytes[12..14], .little) else 0,
        .data_size_bytes = std.mem.readInt(u32, bytes[4..8], .little),
        .profile_version = std.mem.readInt(u16, bytes[2..4], .little),
        .protocol_version = bytes[1],
        .size_bytes = size_bytes,
    };

    assert(result.size_bytes >= header_bytes_min);
    assert(result.size_bytes <= header_bytes_max);

    return result;
}

test Parser {
    const bytes = [_]u8{
        12,   0x20, 0x8F, 0x08,
        14,   0x00, 0x00, 0x00,
        '.',  'F',  'I',  'T',
        0x40, 0x00, 0x00, 0x14,
        0x00, 0x01, 0xFD, 0x04,
        0x86, 0x00, 0x00, 0xCA,
        0x9A, 0x3B,
    };

    var parser: Parser = undefined;

    try parser.init(&bytes);

    const message = switch (try parser.next()) {
        .end => return error.TestUnexpectedResult,
        .message => |message| message,
    };

    try std.testing.expectEqual(@as(u16, 20), message.global_number);
    try std.testing.expectEqual(Endian.little, message.architecture);
    try std.testing.expectEqual(@as(?u32, 1_000_000_000), message.timestamp);

    var fields = message.fields();

    const field = fields.next() orelse return error.TestUnexpectedResult;
    const timestamp = std.mem.readInt(u32, field.bytes[0..4], .little);

    try std.testing.expectEqual(@as(u8, 253), field.number);
    try std.testing.expectEqual(BaseType.uint32, field.base_type);
    try std.testing.expectEqual(@as(usize, 4), field.bytes.len);
    try std.testing.expectEqual(@as(u32, 1_000_000_000), timestamp);

    const field_trailing = fields.next();
    const trailing = try parser.next();

    try std.testing.expect(field_trailing == null);
    try std.testing.expect(trailing == .end);
}

test "a data message before its definition is an error" {
    const bytes = [_]u8{
        12,   0x20, 0x8F, 0x08,
        1,    0x00, 0x00, 0x00,
        '.',  'F',  'I',  'T',
        0x00,
    };

    var parser: Parser = undefined;

    try parser.init(&bytes);

    const result = parser.next();

    try std.testing.expectError(error.LocalTypeUndefined, result);
    try std.testing.expectEqual(@as(u32, 12), parser.diagnostic.offset);
}

test "a non-FIT signature is rejected" {
    const bytes = [_]u8{ 12, 0x20, 0x8F, 0x08, 0, 0, 0, 0, 'N', 'O', 'P', 'E' };

    var parser: Parser = undefined;

    try std.testing.expectError(error.SignatureInvalid, parser.init(&bytes));
}

test "a header whose data size passes the bytes is truncated" {
    const bytes = [_]u8{
        12,  0x20, 0x8F, 0x08,
        64,  0x00, 0x00, 0x00,
        '.', 'F',  'I',  'T',
    };

    var parser: Parser = undefined;

    try std.testing.expectError(error.Truncated, parser.init(&bytes));
}

test "a definition whose base type is not a FIT base type leaves its local type undefined" {
    const bytes = [_]u8{
        12,   0x20, 0x8F, 0x08,
        10,   0x00, 0x00, 0x00,
        '.',  'F',  'I',  'T',
        0x40, 0x00, 0x00, 0x14,
        0x00, 0x01, 0xFD, 0x04,
        0x99, 0x00,
    };

    var parser: Parser = undefined;

    try parser.init(&bytes);

    const definition = parser.next();

    try std.testing.expectError(error.BaseTypeUnknown, definition);
    try std.testing.expect(parser.definitions[0] == null);

    const data = parser.next();

    try std.testing.expectError(error.LocalTypeUndefined, data);
}

test "compressed timestamp records reconstruct an absolute timestamp" {
    const bytes = [_]u8{
        12,   0x20, 0x8F, 0x08,
        25,   0x00, 0x00, 0x00,
        '.',  'F',  'I',  'T',
        0x40, 0x00, 0x00, 0x14,
        0x00, 0x01, 0xFD, 0x04,
        0x86, 0x00, 0xE8, 0x03,
        0x00, 0x00, 0x41, 0x00,
        0x00, 0x15, 0x00, 0x01,
        0x03, 0x01, 0x02, 0xAA,
        0x64,
    };

    var parser: Parser = undefined;

    try parser.init(&bytes);

    const base = (try parser.next()).message;

    try std.testing.expectEqual(@as(?u32, 1000), base.timestamp);

    const compressed = (try parser.next()).message;

    try std.testing.expectEqual(@as(u16, 21), compressed.global_number);
    try std.testing.expectEqual(@as(?u32, 1002), compressed.timestamp);

    var fields = compressed.fields();

    const heart_rate = fields.next() orelse return error.TestUnexpectedResult;
    const trailing = try parser.next();

    try std.testing.expectEqual(@as(u8, 3), heart_rate.number);
    try std.testing.expectEqual(@as(u8, 100), heart_rate.bytes[0]);
    try std.testing.expect(trailing == .end);
}

test "chained files are read one after another and trailing garbage ends the stream" {
    const file = [_]u8{
        12,   0x20, 0x8F, 0x08,
        14,   0x00, 0x00, 0x00,
        '.',  'F',  'I',  'T',
        0x40, 0x00, 0x00, 0x14,
        0x00, 0x01, 0xFD, 0x04,
        0x86, 0x00, 0x00, 0xCA,
        0x9A, 0x3B, 0x00, 0x00,
    };

    const bytes = file ++ file ++ [_]u8{ 0xDE, 0xAD };

    var parser: Parser = undefined;

    try parser.init(&bytes);

    for (0..2) |_| {
        const message = (try parser.next()).message;

        try std.testing.expectEqual(@as(u16, 20), message.global_number);
        try std.testing.expectEqual(@as(?u32, 1_000_000_000), message.timestamp);
    }

    const end_once = try parser.next();
    const end_again = try parser.next();

    try std.testing.expect(end_once == .end);
    try std.testing.expect(end_again == .end);
}

test "developer field definitions are read in full" {
    const bytes = [_]u8{
        12,   0x20, 0x8F, 0x08,
        16,   0x00, 0x00, 0x00,
        '.',  'F',  'I',  'T',
        0x60, 0x00, 0x00, 0x14,
        0x00, 0x00, 0x02, 0x07,
        0x01, 0x00, 0x09, 0x01,
        0x01, 0x00, 0x11, 0x22,
    };

    var parser: Parser = undefined;

    try parser.init(&bytes);

    const message = (try parser.next()).message;

    var developer_fields = message.developer_fields();

    const first = developer_fields.next() orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(@as(u8, 7), first.number);
    try std.testing.expectEqual(@as(u8, 0x11), first.bytes[0]);

    const second = developer_fields.next() orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(@as(u8, 9), second.number);
    try std.testing.expectEqual(@as(u8, 1), second.developer_data_index);
    try std.testing.expectEqual(@as(u8, 0x22), second.bytes[0]);

    const trailing = developer_fields.next();

    try std.testing.expect(trailing == null);
}

test verify_checksum {
    var bytes = [_]u8{ 12, 0x20, 0x8F, 0x08, 0, 0, 0, 0, '.', 'F', 'I', 'T', 0, 0 };

    const sum = crc.checksum(bytes[0..12]);

    std.mem.writeInt(u16, bytes[12..14], sum, .little);

    try verify_checksum(&bytes);

    bytes[2] ^= 0xFF;

    try std.testing.expectError(error.ChecksumMismatch, verify_checksum(&bytes));
    try std.testing.expectError(error.Truncated, verify_checksum(&[_]u8{ 1, 2, 3 }));
}

const std = @import("std");

const bounded = @import("bounded");
const json = @import("json");

const fit = @import("fit.zig");
const garmin = @import("garmin.zig");

const Writer = std.Io.Writer;
const assert = std.debug.assert;

const Message = fit.Decoder.Message;
const Value = fit.Decoder.Value;

pub const Decoder = fit.DecoderType(.{
    .accumulator_count_max = 256,
    .developer_field_count_max = 256,
    .field_count_max = 1024,
    .text_bytes_max = 64 * 1024,
});

pub const CapacityError = error{ColumnsExhausted};
pub const Error = CapacityError || fit.Decoder.Error || Writer.Error;

const JSONError = json.Writer.CapacityError || error{FloatNonFinite} || Writer.Error;

pub const Columns = struct {
    index: bounded.MapType(u32, column_count_max),
    names: bounded.ArrayType([]const u8, column_count_max),
    row: [column_count_max]?Value,
    text: bounded.BufferType(column_text_bytes_max),

    pub fn init(columns: *Columns) void {
        assert(column_count_max > fit.limits.field_count_max);
        assert(column_text_bytes_max > column_count_max);

        columns.index.init(.{ .seed = column_seed });
        columns.names = .empty;
        columns.text = .empty;

        assert(columns.names.count == 0);
    }

    fn column_add(columns: *Columns, name: []const u8) CapacityError!void {
        assert(name.len > 0);
        assert(columns.names.count == columns.index.count);

        if (columns.index.get(name) != null) return;
        if (columns.names.full()) return error.ColumnsExhausted;

        const start = columns.text.count();

        columns.text.push(name) catch return error.ColumnsExhausted;

        const stored = columns.text.slice()[start..];
        const column = columns.names.count;

        columns.names.push_slot_assume_capacity().* = stored;
        columns.index.set(stored, column) catch return error.ColumnsExhausted;

        assert(columns.index.get(stored).? == column);
    }

    fn row_fill(columns: *Columns, message: *const Message) void {
        assert(columns.names.count == columns.index.count);
        assert(message.name.len > 0);

        const row = columns.row[0..columns.names.count];

        @memset(row, null);

        for (message.fields) |field| {
            const column = columns.index.get(field.name) orelse continue;

            assert(column < row.len);

            if (row[column] == null) row[column] = field.value;
        }
    }
};

const ChannelSample = struct {
    id: u64,
    value: u64,
};

const column_count_max: u32 = 2048;
const column_seed: u64 = 0x2f17;
const column_text_bytes_max: u32 = 256 * 1024;
const csv_quoting_bytes = ",\"\n\r";
const global_number_invalid: u16 = 0xFFFF;
const timestamp_invalid: u32 = 0xFFFFFFFF;
const json_depth_max: u32 = 3;

const json_options: json.Writer.Options = .{
    .indent = 4,
    .layout = .compact,
    .non_finite = .null_value,
    .notation = .ecmascript,
    .utf8 = .checked,
};

comptime {
    assert(json_depth_max <= json.limits.depth_max);
    assert(global_number_invalid == std.math.maxInt(u16));
    assert(json_options.layout == .compact);
    assert(json_options.non_finite == .null_value);
}

pub fn write_json(decoder: *Decoder, bytes: []const u8, out: *Writer) Error!void {
    assert(bytes.len <= fit.limits.source_bytes_max);
    assert(out.buffer.len > 0);

    try decoder.init(bytes);
    try out.writeAll("[\n");

    for (0..fit.limits.message_count_max) |index| {
        const message = switch (try decoder.next()) {
            .end => break,
            .message => |message| message,
        };

        if (index > 0) try out.writeAll(",\n");

        message_json_write(&message, out) catch |err| switch (err) {
            error.DepthExceeded, error.FloatNonFinite => unreachable,
            error.WriteFailed => return error.WriteFailed,
        };
    }

    try out.writeAll("\n]\n");
}

pub fn write_csv(
    decoder: *Decoder,
    columns: *Columns,
    bytes: []const u8,
    out: *Writer,
    global_number: u16,
) Error!void {
    assert(global_number != global_number_invalid);
    assert(bytes.len <= fit.limits.source_bytes_max);

    try columns_collect(decoder, columns, bytes, global_number);
    try out.writeAll("timestamp_unix");

    for (columns.names.slice()) |name| {
        try out.writeAll(",");
        try csv_field_write(out, name);
    }

    try out.writeAll("\n");
    try decoder.init(bytes);

    for (0..fit.limits.message_count_max) |_| {
        const message = switch (try decoder.next()) {
            .end => break,
            .message => |message| message,
        };

        if (message.global_number != global_number) continue;

        columns.row_fill(&message);

        try csv_row_write(out, columns.row[0..columns.names.count], message.timestamp);
    }
}

pub fn write_channels(decoder: *Decoder, bytes: []const u8, out: *Writer) Error!void {
    assert(bytes.len <= fit.limits.source_bytes_max);
    assert(out.buffer.len > 0);

    try decoder.init(bytes);
    try out.writeAll("index,timestamp_unix,channel,value\n");

    var index: u32 = 0;

    for (0..fit.limits.message_count_max) |_| {
        const message = switch (try decoder.next()) {
            .end => break,
            .message => |message| message,
        };

        if (message.global_number != garmin.channel_message_number) continue;

        const sample = channel_sample(&message) orelse continue;

        try channel_row_write(out, index, decoder.timestamp_last(), sample);

        index += 1;
    }
}

fn message_json_write(message: *const Message, out: *Writer) JSONError!void {
    assert(message.name.len > 0);
    assert(message.fields.len <= fit.limits.message_count_max);

    var writer: json.Writer = .init(out, json_options);

    try out.writeAll("  ");
    try writer.object_begin();
    try writer.key("message");
    try writer.string(message.name);
    try writer.key("global");
    try writer.unsigned(message.global_number);

    if (message.timestamp) |timestamp| {
        const seconds = fit.unix_seconds_of(timestamp) orelse unreachable;

        try writer.key("timestamp");
        try writer.integer(seconds);
    }

    try writer.key("fields");
    try writer.object_begin();

    for (message.fields) |*field| {
        try writer.key(field.name);
        try value_json_write(&writer, &field.value);
    }

    try writer.object_end();
    try writer.object_end();

    writer.finish();
}

fn value_json_write(writer: *json.Writer, value: *const Value) JSONError!void {
    assert(writer.options.non_finite == .null_value);

    switch (value.*) {
        .none => try writer.null_value(),
        .integer => |number| try writer.integer(number),
        .unsigned => |number| try writer.unsigned(number),
        .real => |number| try writer.float(number),
        .string => |text| try writer.string(text),
        .enumeration => |name| try writer.string(name),
        .bytes => |bytes| try hex_string_write(writer, bytes),
        .integer_array => |*array| {
            try writer.array_begin();

            for (0..array.count()) |index| {
                try writer.integer(array.integer_of(@intCast(index)));
            }

            try writer.array_end();
        },
        .real_array => |*array| {
            try writer.array_begin();

            for (0..array.count()) |index| {
                try writer.float(array.real_of(@intCast(index)));
            }

            try writer.array_end();
        },
    }
}

fn hex_string_write(writer: *json.Writer, bytes: []const u8) Writer.Error!void {
    assert(bytes.len <= fit.limits.field_count_max);
    assert(writer.options.utf8 == .checked);

    try writer.string_begin();

    for (bytes) |byte| try writer.string_part(&std.fmt.hex(byte));

    try writer.string_end();
}

fn columns_collect(
    decoder: *Decoder,
    columns: *Columns,
    bytes: []const u8,
    global_number: u16,
) Error!void {
    assert(bytes.len <= fit.limits.source_bytes_max);
    assert(global_number != global_number_invalid);
    assert(columns.names.count == 0);

    try decoder.init(bytes);

    for (0..fit.limits.message_count_max) |_| {
        const message = switch (try decoder.next()) {
            .end => break,
            .message => |message| message,
        };

        if (message.global_number != global_number) continue;

        for (message.fields) |field| try columns.column_add(field.name);
    }

    assert(columns.names.count == columns.index.count);
}

fn csv_row_write(out: *Writer, row: []const ?Value, timestamp: ?u32) Writer.Error!void {
    assert(row.len <= column_count_max);
    assert(out.buffer.len > 0);

    if (timestamp) |found| assert(found != timestamp_invalid);

    if (timestamp) |found| {
        const seconds = fit.unix_seconds_of(found) orelse unreachable;

        try out.print("{d}", .{seconds});
    }

    for (row) |cell| {
        try out.writeAll(",");

        if (cell) |*value| try value_csv_write(out, value);
    }

    try out.writeAll("\n");
}

fn value_csv_write(out: *Writer, value: *const Value) Writer.Error!void {
    assert(out.buffer.len > 0);

    switch (value.*) {
        .none => {},
        .integer => |number| try out.print("{d}", .{number}),
        .unsigned => |number| try out.print("{d}", .{number}),
        .real => |number| try out.print("{d}", .{number}),
        .string => |text| try csv_field_write(out, text),
        .enumeration => |name| try csv_field_write(out, name),
        .bytes => |bytes| for (bytes) |byte| try out.print("{x:0>2}", .{byte}),
        .integer_array => |*array| for (0..array.count()) |index| {
            if (index > 0) try out.writeAll(" ");

            try out.print("{d}", .{array.integer_of(@intCast(index))});
        },
        .real_array => |*array| for (0..array.count()) |index| {
            if (index > 0) try out.writeAll(" ");

            try out.print("{d}", .{array.real_of(@intCast(index))});
        },
    }
}

fn csv_field_write(out: *Writer, text: []const u8) Writer.Error!void {
    assert(out.buffer.len > 0);
    assert(text.len <= column_text_bytes_max);

    if (std.mem.findAny(u8, text, csv_quoting_bytes) == null) {
        try out.writeAll(text);

        return;
    }

    try out.writeAll("\"");

    for (text) |byte| {
        if (byte == '"') {
            try out.writeAll("\"\"");
        } else {
            try out.writeByte(byte);
        }
    }

    try out.writeAll("\"");
}

fn channel_sample(message: *const Message) ?ChannelSample {
    assert(message.global_number == garmin.channel_message_number);
    assert(message.name.len > 0);

    var id: ?u64 = null;
    var value: ?u64 = null;

    for (message.fields) |field| {
        const unsigned = switch (field.value) {
            .unsigned => |number| number,
            .none, .integer, .real, .string, .enumeration, .bytes => continue,
            .integer_array, .real_array => continue,
        };

        if (std.mem.eql(u8, field.name, garmin.channel_field_name)) id = unsigned;
        if (std.mem.eql(u8, field.name, garmin.channel_value_field_name)) value = unsigned;
    }

    const found_id = id orelse return null;
    const found_value = value orelse return null;

    if (found_id > std.math.maxInt(u5)) return null;
    if (found_value > std.math.maxInt(u27)) return null;
    return .{ .id = found_id, .value = found_value };
}

fn channel_row_write(
    out: *Writer,
    index: u32,
    timestamp: ?u32,
    sample: ChannelSample,
) Writer.Error!void {
    assert(index < fit.limits.message_count_max);
    assert(sample.id <= std.math.maxInt(u5));
    assert(sample.value <= std.math.maxInt(u27));

    if (timestamp) |found| assert(found != timestamp_invalid);

    try out.print("{d},", .{index});

    if (timestamp) |found| {
        const seconds = fit.unix_seconds_of(found) orelse unreachable;

        try out.print("{d}", .{seconds});
    }

    try out.print(",{d},{d}\n", .{ sample.id, sample.value });
}

const ExportedDocument = json.DocumentType(.{ .node_count_max = 1024, .text_bytes_max = 4096 });

const TestState = struct {
    decoder: Decoder,
    document: ExportedDocument,
    encoded: [4096]u8,
    exported: [16 * 1024]u8,
};

const fixture_integers = [_]i64{
    std.math.minInt(i64),
    -1,
    0,
    1,
    std.math.maxInt(i64) - 1,
};

const fixture_reals = [_]f64{ -2.5e-10, 1.5e9, std.math.nan(f64) };

const fixture_text = "quote \" backslash \\ controls \x00\x01\x08\t\n\x0c\r\x1f\x7f" ++
    " latin \u{e9} cjk \u{65e5} astral \u{1f600}";

const fixture_integer_bytes = numbers_encode(i64, &fixture_integers);
const fixture_real_bytes = numbers_encode(f64, &fixture_reals);

const fixture_fields = [_]fit.Decoder.Field{
    fixture_field("bytes", &.{ .bytes = &.{ 0x00, 0x7f, 0x80, 0xff } }),
    fixture_field("enumeration", &.{ .enumeration = "activity" }),
    fixture_field("integer_array", &.{ .integer_array = .{
        .architecture = .little,
        .base_type = .sint64,
        .bytes = &fixture_integer_bytes,
        .offset = 0.0,
        .scale = 1.0,
    } }),
    fixture_field("integer_max", &.{ .integer = std.math.maxInt(i64) }),
    fixture_field("integer_min", &.{ .integer = std.math.minInt(i64) }),
    fixture_field("key \"quoted\" \\ \u{e9}", &.{ .unsigned = 0 }),
    fixture_field("none", &.none),
    fixture_field("real", &.{ .real = 0.1 }),
    fixture_field("real_array", &.{ .real_array = .{
        .architecture = .little,
        .base_type = .float64,
        .bytes = &fixture_real_bytes,
        .offset = 0.0,
        .scale = 1.0,
    } }),
    fixture_field("real_infinity", &.{ .real = -std.math.inf(f64) }),
    fixture_field("real_largest", &.{ .real = std.math.floatMax(f64) }),
    fixture_field("real_nan", &.{ .real = std.math.nan(f64) }),
    fixture_field("real_negative_zero", &.{ .real = -0.0 }),
    fixture_field("real_subnormal", &.{ .real = std.math.floatTrueMin(f64) }),
    fixture_field("string", &.{ .string = fixture_text }),
    fixture_field("unsigned_max", &.{ .unsigned = std.math.maxInt(u64) }),
};

const fixture_message: Message = .{
    .fields = &fixture_fields,
    .global_number = std.math.maxInt(u16),
    .name = "fixture",
    .timestamp = std.math.maxInt(u32) - 1,
};

fn numbers_encode(comptime Number: type, comptime numbers: []const Number) [numbers.len * 8]u8 {
    comptime assert(@sizeOf(Number) == 8);
    comptime assert(numbers.len > 0);

    var result: [numbers.len * 8]u8 = undefined;

    for (numbers, 0..) |number, index| {
        const bits: u64 = @bitCast(number);

        std.mem.writeInt(u64, result[index * 8 ..][0..8], bits, .little);
    }

    return result;
}

fn fixture_field(name: []const u8, value: *const Value) fit.Decoder.Field {
    assert(name.len > 0);
    assert(name.len <= fit.limits.field_count_max);

    return .{ .name = name, .number = 0, .type_name = "", .units = "", .value = value.* };
}

fn product_name_encode(buffer: []u8, product_name: []const u8) ![]const u8 {
    assert(product_name.len > 0);
    assert(buffer.len > product_name.len);

    var encoder: fit.Encoder = undefined;

    encoder.init(buffer);

    try encoder.write_message(&.{
        .fields = &.{.{ .number = 8, .value = .{ .string = product_name } }},
        .global_number = 0,
    });

    const result = encoder.close();

    assert(result.len > product_name.len);

    return result;
}

fn expect_export_decoded(
    decoder: *Decoder,
    document: *const json.Document,
    bytes: []const u8,
) !void {
    try std.testing.expect(bytes.len > 0);

    const root = document.root();

    try std.testing.expect(document.kind_of(root) == .array);
    try decoder.init(bytes);

    var items = document.items(root);
    var count: u32 = 0;

    for (0..fit.limits.message_count_max) |_| {
        const message = switch (try decoder.next()) {
            .end => break,
            .message => |message| message,
        };

        const item = items.next() orelse return error.TestUnexpectedResult;

        try expect_message_exported(document, item, &message);

        count += 1;
    }

    try std.testing.expect(count > 0);
    try std.testing.expectEqual(count, document.count_of(root));
}

fn expect_message_exported(
    document: *const json.Document,
    node: json.Node,
    message: *const Message,
) !void {
    try std.testing.expect(document.kind_of(node) == .object);

    const fields = document.member(node, "fields") orelse return error.TestUnexpectedResult;
    const global = document.member(node, "global") orelse return error.TestUnexpectedResult;
    const name = document.member(node, "message") orelse return error.TestUnexpectedResult;
    const member_count: u32 = if (message.timestamp == null) 3 else 4;

    try std.testing.expectEqual(member_count, document.count_of(node));
    try std.testing.expect(document.text_is(name, message.name));
    try expect_integer_exported(u16, document, global, message.global_number);

    if (message.timestamp) |seconds| {
        const timestamp = document.member(node, "timestamp") orelse
            return error.TestUnexpectedResult;

        const unix = fit.unix_seconds_of(seconds) orelse return error.TestUnexpectedResult;

        try expect_integer_exported(i64, document, timestamp, unix);
    }

    try std.testing.expect(document.kind_of(fields) == .object);
    try std.testing.expectEqual(message.fields.len, document.count_of(fields));

    var entries = document.entries(fields);

    for (message.fields) |*field| {
        const entry = entries.next() orelse return error.TestUnexpectedResult;

        try std.testing.expect(document.text_is(entry.key, field.name));
        try expect_value_exported(document, entry.value, &field.value);
    }
}

fn expect_value_exported(
    document: *const json.Document,
    node: json.Node,
    value: *const Value,
) !void {
    try std.testing.expect(document.kind_of(node) != .object);

    switch (value.*) {
        .none => try std.testing.expect(document.kind_of(node) == .null_value),
        .integer => |number| try expect_integer_exported(i64, document, node, number),
        .unsigned => |number| try expect_integer_exported(u64, document, node, number),
        .real => |number| try expect_real_exported(document, node, number),
        .string => |text| try std.testing.expect(document.text_is(node, text)),
        .enumeration => |name| try std.testing.expect(document.text_is(node, name)),
        .bytes => |bytes| try expect_bytes_exported(document, node, bytes),
        .integer_array, .real_array => |*array| {
            try std.testing.expect(document.kind_of(node) == .array);
            try std.testing.expectEqual(array.count(), document.count_of(node));

            var items = document.items(node);

            for (0..array.count()) |position| {
                const index: u32 = @intCast(position);
                const item = items.next() orelse return error.TestUnexpectedResult;

                if (value.* == .integer_array) {
                    try expect_integer_exported(i64, document, item, array.integer_of(index));
                } else {
                    try expect_real_exported(document, item, array.real_of(index));
                }
            }
        },
    }
}

fn expect_integer_exported(
    comptime Integer: type,
    document: *const json.Document,
    node: json.Node,
    number: Integer,
) !void {
    try std.testing.expect(document.kind_of(node) == .number);

    const parsed = try std.fmt.parseInt(Integer, document.source_of(node), 10);

    try std.testing.expectEqual(number, parsed);
}

fn expect_real_exported(document: *const json.Document, node: json.Node, number: f64) !void {
    try std.testing.expect(std.math.isFinite(number) == (document.kind_of(node) == .number));

    if (!std.math.isFinite(number)) {
        try std.testing.expect(document.kind_of(node) == .null_value);

        return;
    }

    const parsed = try std.fmt.parseFloat(f64, document.source_of(node));

    try std.testing.expectEqual(number, parsed);
    try std.testing.expectEqual(std.math.signbit(number), std.math.signbit(parsed));
}

fn expect_bytes_exported(document: *const json.Document, node: json.Node, bytes: []const u8) !void {
    try std.testing.expect(document.kind_of(node) == .string);

    var buffer: [fit.limits.field_count_max]u8 = undefined;

    const text = document.text_of(node) orelse return error.TestUnexpectedResult;
    const decoded = try std.fmt.hexToBytes(&buffer, text);

    try std.testing.expectEqualSlices(u8, bytes, decoded);
}

test write_json {
    const state = try std.testing.allocator.create(TestState);
    defer std.testing.allocator.destroy(state);

    var encoder: fit.Encoder = undefined;

    encoder.init(&state.encoded);

    try encoder.write_message(&.{
        .fields = &.{
            .{ .number = 0, .value = .{ .enum_value = 4 } },
            .{ .number = 8, .value = .{ .string = "quote \" backslash \\ caf\u{e9}" } },
        },
        .global_number = 0,
    });

    try encoder.write_message(&.{
        .fields = &.{
            .{ .number = 253, .value = .{ .uint32 = 1_000_000_000 } },
            .{ .number = 0, .value = .{ .sint32 = -123_456_789 } },
            .{ .number = 2, .value = .{ .uint16 = 3000 } },
            .{ .number = 3, .value = .{ .uint8 = 0xff } },
            .{ .number = 6, .value = .{ .uint16 = 3050 } },
        },
        .global_number = 20,
    });

    const bytes = encoder.close();

    var exported: Writer = .fixed(&state.exported);

    try write_json(&state.decoder, bytes, &exported);

    const written = exported.buffered();

    try std.testing.expect(std.mem.startsWith(u8, written, "[\n  {\"message\":"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, written, "}},\n  {\"message\":"));
    try std.testing.expect(std.mem.endsWith(u8, written, "}}\n]\n"));
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, written, "\n"));

    try state.document.parse(written);
    try std.testing.expectEqual(@as(u32, 2), state.document.count_of(state.document.root()));
    try expect_export_decoded(&state.decoder, &state.document.base, bytes);
}

test "json export escapes every control byte a fit string can hold" {
    const state = try std.testing.allocator.create(TestState);
    defer std.testing.allocator.destroy(state);

    var product_name: [0x1f]u8 = undefined;

    for (&product_name, 1..) |*byte, code| byte.* = @intCast(code);

    const bytes = try product_name_encode(&state.encoded, &product_name);

    var exported: Writer = .fixed(&state.exported);

    try write_json(&state.decoder, bytes, &exported);
    try state.document.parse(exported.buffered());

    const root = state.document.root();

    const field = state.document.pointer_find(root, "/0/fields/product_name") orelse
        return error.TestUnexpectedResult;

    try std.testing.expect(state.document.text_is(field, &product_name));
    try expect_export_decoded(&state.decoder, &state.document.base, bytes);
}

test "json export reads back every value kind as its source value" {
    const state = try std.testing.allocator.create(TestState);
    defer std.testing.allocator.destroy(state);

    var exported: Writer = .fixed(&state.exported);

    try message_json_write(&fixture_message, &exported);
    try state.document.parse(exported.buffered());
    try expect_message_exported(&state.document.base, state.document.root(), &fixture_message);

    const root = state.document.root();
    const integers = state.document.pointer_find(root, "/fields/integer_array").?;
    const reals = state.document.pointer_find(root, "/fields/real_array").?;

    var items = state.document.items(integers);

    for (fixture_integers) |number| {
        const item = items.next() orelse return error.TestUnexpectedResult;

        try expect_integer_exported(i64, &state.document.base, item, number);
    }

    var real_items = state.document.items(reals);

    for (fixture_reals) |number| {
        const item = real_items.next() orelse return error.TestUnexpectedResult;

        try expect_real_exported(&state.document.base, item, number);
    }
}

test "json export writes each byte outside a utf-8 sequence as its code point" {
    const state = try std.testing.allocator.create(TestState);
    defer std.testing.allocator.destroy(state);

    const fields = [_]fit.Decoder.Field{
        fixture_field("invalid \xfe", &.{ .string = "a\xffb\xc3" }),
    };

    const message: Message = .{
        .fields = &fields,
        .global_number = 0,
        .name = "invalid",
        .timestamp = null,
    };

    var exported: Writer = .fixed(&state.exported);

    try message_json_write(&message, &exported);
    try state.document.parse(exported.buffered());

    const root = state.document.root();

    const field = state.document.pointer_find(root, "/fields/invalid \u{fe}") orelse
        return error.TestUnexpectedResult;

    try std.testing.expect(state.document.text_is(field, "a\u{ff}b\u{c3}"));
}

test write_csv {
    const state = try std.testing.allocator.create(TestState);
    defer std.testing.allocator.destroy(state);

    const columns = try std.testing.allocator.create(Columns);
    defer std.testing.allocator.destroy(columns);

    columns.init();

    const bytes = try product_name_encode(&state.encoded, "a\rb");

    var exported: Writer = .fixed(&state.exported);

    try write_csv(&state.decoder, columns, bytes, &exported, 0);

    const expected = "timestamp_unix,product_name\n,\"a\rb\"\n";

    try std.testing.expectEqualStrings(expected, exported.buffered());
}

test write_channels {
    const state = try std.testing.allocator.create(TestState);
    defer std.testing.allocator.destroy(state);

    var encoder: fit.Encoder = undefined;

    encoder.init(&state.encoded);

    try encoder.write_message(&.{
        .fields = &.{.{ .number = 253, .value = .{ .uint32 = 1000 } }},
        .global_number = 20,
    });

    try encoder.write_message(&.{
        .fields = &.{.{ .number = 2, .value = .{ .uint32 = 0x180000A2 } }},
        .global_number = 233,
    });

    var exported: Writer = .fixed(&state.exported);

    try write_channels(&state.decoder, encoder.close(), &exported);

    const expected = "index,timestamp_unix,channel,value\n0,631066600,3,162\n";

    try std.testing.expectEqualStrings(expected, exported.buffered());
}

const std = @import("std");

const json = @import("json");

const Decoder = @import("decoder.zig");
const Encoder = @import("encoder.zig");
const decode = @import("decode.zig");
const epoch = @import("epoch.zig");
const garmin = @import("garmin.zig");
const value_module = @import("value.zig");

const Allocator = std.mem.Allocator;
const Message = decode.Message;
const Value = value_module.Value;
const Writer = std.Io.Writer;
const assert = std.debug.assert;

pub const Error = decode.Error || Writer.Error;
const JSONError = Error || json.Writer.CapacityError || error{FloatNonFinite};

const Columns = struct {
    names: []const []const u8,
    index_of: std.StringHashMapUnmanaged(u32),

    fn deinit(columns: *Columns, gpa: Allocator) void {
        assert(columns.names.len == columns.index_of.count());

        columns.index_of.deinit(gpa);
    }
};

const ChannelSample = struct {
    id: u64,
    value: u64,
};

const message_count_max = Decoder.message_count_max;

const column_count_max = 4096;
const csv_quoting_bytes = ",\"\n\r";
const json_depth_max = 3;

const json_options: json.Writer.Options = .{
    .layout = .compact,
    .non_finite = .null_value,
    .notation = .ecmascript,
    .utf8 = .checked,
};

comptime {
    assert(column_count_max > Decoder.field_count_max);
    assert(json_depth_max <= json.limits.depth_max);
    assert(json_options.layout == .compact);
    assert(json_options.non_finite == .null_value);
}

pub fn write_json(out: *Writer, gpa: Allocator, bytes: []const u8) Error!void {
    var reader = std.Io.Reader.fixed(bytes);
    var decoder = try Decoder.init(&reader);
    var stream = decode.Stream.init(&decoder, gpa);
    defer stream.deinit();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    try out.writeAll("[\n");

    var count: u32 = 0;

    while (count < message_count_max) : (count += 1) {
        _ = arena_state.reset(.retain_capacity);

        const message = switch (try stream.next(arena_state.allocator())) {
            .end => break,
            .message => |message| message,
        };

        if (count > 0) try out.writeAll(",\n");

        write_message_json(out, message) catch |err| switch (err) {
            error.DepthExceeded, error.FloatNonFinite => unreachable,
            else => |narrowed| return narrowed,
        };
    }

    try out.writeAll("\n]\n");
}

fn write_message_json(out: *Writer, message: Message) JSONError!void {
    assert(message.name.len > 0);

    var writer: json.Writer = .init(out, json_options);

    try out.writeAll("  ");
    try writer.object_begin();
    try writer.key("message");
    try writer.string(message.name);
    try writer.key("global");
    try writer.unsigned(message.global_number);

    if (message.timestamp) |timestamp| {
        try writer.key("timestamp");
        try writer.integer(epoch.to_unix_seconds(timestamp));
    }

    try writer.key("fields");
    try writer.object_begin();

    for (message.fields) |field| {
        assert(field.name.len > 0);

        try writer.key(field.name);
        try write_value_json(&writer, field.value);
    }

    try writer.object_end();
    try writer.object_end();
    writer.finish();
}

fn write_value_json(writer: *json.Writer, value: Value) JSONError!void {
    switch (value) {
        .none => try writer.null_value(),
        .integer => |number| try writer.integer(number),
        .unsigned => |number| try writer.unsigned(number),
        .real => |number| try writer.float(number),
        .string => |text| try writer.string(text),
        .enumeration => |name| try writer.string(name),
        .bytes => |data| try write_hex_string(writer, data),
        .integer_array => |items| {
            assert(items.len <= Decoder.field_bytes_max);

            try writer.array_begin();

            for (items) |item| try writer.integer(item);

            try writer.array_end();
        },
        .real_array => |items| {
            assert(items.len <= Decoder.field_bytes_max);

            try writer.array_begin();

            for (items) |item| try writer.float(item);

            try writer.array_end();
        },
    }
}

pub fn write_csv(out: *Writer, gpa: Allocator, bytes: []const u8, global_number: u16) Error!void {
    var columns_arena = std.heap.ArenaAllocator.init(gpa);
    defer columns_arena.deinit();

    const columns_allocator = columns_arena.allocator();

    var columns = try collect_columns(gpa, columns_allocator, bytes, global_number);
    defer columns.deinit(gpa);

    const row = try columns_allocator.alloc(?Value, columns.names.len);

    assert(row.len == columns.names.len);
    assert(row.len <= column_count_max);

    try out.writeAll("timestamp_unix");

    for (columns.names) |name| {
        try out.writeAll(",");
        try write_csv_field(out, name);
    }

    try out.writeAll("\n");

    var reader = std.Io.Reader.fixed(bytes);
    var decoder = try Decoder.init(&reader);
    var stream = decode.Stream.init(&decoder, gpa);
    defer stream.deinit();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var count: u32 = 0;

    while (count < message_count_max) : (count += 1) {
        _ = arena_state.reset(.retain_capacity);

        const message = switch (try stream.next(arena_state.allocator())) {
            .end => break,
            .message => |message| message,
        };

        if (message.global_number != global_number) continue;

        fill_row(&columns, row, message);

        try write_csv_row(out, row, message.timestamp);
    }
}

fn fill_row(columns: *const Columns, row: []?Value, message: Message) void {
    assert(row.len == columns.names.len);
    assert(row.len == columns.index_of.count());

    @memset(row, null);

    for (message.fields) |field| {
        const column = columns.index_of.get(field.name) orelse continue;

        assert(column < row.len);
        assert(std.mem.eql(u8, columns.names[column], field.name));

        if (row[column] == null) row[column] = field.value;
    }
}

fn write_csv_row(out: *Writer, row: []const ?Value, timestamp: ?u32) Error!void {
    assert(row.len <= column_count_max);

    if (timestamp) |seconds| {
        try out.print("{d}", .{epoch.to_unix_seconds(seconds)});
    }

    for (row) |cell| {
        try out.writeAll(",");
        if (cell) |value| try write_value_csv(out, value);
    }

    try out.writeAll("\n");
}

pub fn write_channels_233(out: *Writer, gpa: Allocator, bytes: []const u8) Error!void {
    var reader = std.Io.Reader.fixed(bytes);
    var decoder = try Decoder.init(&reader);
    var stream = decode.Stream.init(&decoder, gpa);
    defer stream.deinit();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    try out.writeAll("index,timestamp_unix,channel,value\n");

    var count: u32 = 0;
    var index: u32 = 0;

    while (count < message_count_max) : (count += 1) {
        _ = arena_state.reset(.retain_capacity);

        const message = switch (try stream.next(arena_state.allocator())) {
            .end => break,
            .message => |message| message,
        };

        if (message.global_number != garmin.channel_message_number) continue;

        const sample = channel_sample(message) orelse continue;

        try write_channel_row(out, index, stream.decoder.timestamp, sample);

        index += 1;
    }
}

fn channel_sample(message: Message) ?ChannelSample {
    assert(message.global_number == garmin.channel_message_number);

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

fn write_channel_row(
    out: *Writer,
    index: u32,
    timestamp: ?u32,
    sample: ChannelSample,
) Error!void {
    assert(sample.id <= std.math.maxInt(u5));
    assert(sample.value <= std.math.maxInt(u27));

    try out.print("{d},", .{index});

    if (timestamp) |seconds| try out.print("{d}", .{epoch.to_unix_seconds(seconds)});

    try out.print(",{d},{d}\n", .{ sample.id, sample.value });
}

fn collect_columns(
    gpa: Allocator,
    storage: Allocator,
    bytes: []const u8,
    global_number: u16,
) Error!Columns {
    var reader = std.Io.Reader.fixed(bytes);
    var decoder = try Decoder.init(&reader);
    var stream = decode.Stream.init(&decoder, gpa);
    defer stream.deinit();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var names: std.ArrayList([]const u8) = .empty;
    var index_of: std.StringHashMapUnmanaged(u32) = .empty;
    errdefer index_of.deinit(gpa);

    var count: u32 = 0;

    while (count < message_count_max) : (count += 1) {
        _ = arena_state.reset(.retain_capacity);

        const message = switch (try stream.next(arena_state.allocator())) {
            .end => break,
            .message => |message| message,
        };

        if (message.global_number != global_number) continue;
        if (names.items.len == column_count_max) break;

        for (message.fields) |field| {
            if (names.items.len == column_count_max) break;
            if (index_of.contains(field.name)) continue;

            const owned = try storage.dupe(u8, field.name);
            const column: u32 = @intCast(names.items.len);

            try index_of.put(gpa, owned, column);
            try names.append(storage, owned);

            assert(index_of.get(owned).? == column);
        }
    }

    assert(names.items.len == index_of.count());
    assert(names.items.len <= column_count_max);

    return .{ .names = names.items, .index_of = index_of };
}

fn write_value_csv(out: *Writer, value: Value) Error!void {
    switch (value) {
        .none => {},
        .integer => |number| try out.print("{d}", .{number}),
        .unsigned => |number| try out.print("{d}", .{number}),
        .real => |number| try out.print("{d}", .{number}),
        .string => |text| try write_csv_field(out, text),
        .enumeration => |name| try write_csv_field(out, name),
        .bytes => |data| for (data) |byte| try out.print("{x:0>2}", .{byte}),
        .integer_array => |items| for (items, 0..) |item, index| {
            if (index > 0) try out.writeAll(" ");

            try out.print("{d}", .{item});
        },
        .real_array => |items| for (items, 0..) |item, index| {
            if (index > 0) try out.writeAll(" ");

            try out.print("{d}", .{item});
        },
    }
}

fn write_csv_field(out: *Writer, text: []const u8) Error!void {
    if (std.mem.findAny(u8, text, csv_quoting_bytes) == null) {
        try out.writeAll(text);

        return;
    }

    try out.writeAll("\"");

    for (text) |byte| {
        if (byte == '"') try out.writeAll("\"\"") else try out.writeByte(byte);
    }

    try out.writeAll("\"");
}

fn write_hex_string(writer: *json.Writer, data: []const u8) Writer.Error!void {
    assert(data.len <= Decoder.field_bytes_max);

    try writer.string_begin();

    for (data) |byte| try writer.string_part(&std.fmt.hex(byte));

    try writer.string_end();
}

const ExportedDocument = json.DocumentType(.{ .node_count_max = 1024, .text_bytes_max = 4096 });
const fixture_integers = [_]i64{ std.math.minInt(i64), -1, 0, 1, std.math.maxInt(i64) };
const fixture_reals = [_]f64{ -2.5e-10, 1.5e9, std.math.nan(f64) };

const fixture_text = "quote \" backslash \\ controls \x00\x01\x08\t\n\x0c\r\x1f\x7f" ++
    " latin \u{e9} cjk \u{65e5} astral \u{1f600}";

const fixture_fields = [_]decode.Field{
    fixture_field("bytes", .{ .bytes = &.{ 0x00, 0x7f, 0x80, 0xff } }),
    fixture_field("enumeration", .{ .enumeration = "activity" }),
    fixture_field("integer_array", .{ .integer_array = &fixture_integers }),
    fixture_field("integer_max", .{ .integer = std.math.maxInt(i64) }),
    fixture_field("integer_min", .{ .integer = std.math.minInt(i64) }),
    fixture_field("key \"quoted\" \\ \u{e9}", .{ .unsigned = 0 }),
    fixture_field("none", .none),
    fixture_field("real", .{ .real = 0.1 }),
    fixture_field("real_array", .{ .real_array = &fixture_reals }),
    fixture_field("real_infinity", .{ .real = -std.math.inf(f64) }),
    fixture_field("real_largest", .{ .real = std.math.floatMax(f64) }),
    fixture_field("real_nan", .{ .real = std.math.nan(f64) }),
    fixture_field("real_negative_zero", .{ .real = -0.0 }),
    fixture_field("real_subnormal", .{ .real = std.math.floatTrueMin(f64) }),
    fixture_field("string", .{ .string = fixture_text }),
    fixture_field("unsigned_max", .{ .unsigned = std.math.maxInt(u64) }),
};

const fixture_message: Message = .{
    .global_number = std.math.maxInt(u16),
    .name = "fixture",
    .timestamp = std.math.maxInt(u32),
    .fields = &fixture_fields,
};

fn fixture_field(name: []const u8, value: Value) decode.Field {
    assert(name.len > 0);

    return .{ .number = 0, .name = name, .fit_type = "", .units = "", .value = value };
}

fn encoded_product_name(gpa: Allocator, product_name: []const u8) ![]u8 {
    assert(product_name.len > 0);

    const file_id_number: u16 = 0;
    const product_name_number: u8 = 8;

    var encoder = Encoder.init(gpa);
    defer encoder.deinit();

    try encoder.message(file_id_number, &.{.{
        .number = product_name_number,
        .value = .{ .string = product_name },
    }});

    var encoded: Writer.Allocating = .init(gpa);
    errdefer encoded.deinit();

    try encoder.finish(&encoded.writer);

    const bytes = try encoded.toOwnedSlice();

    assert(bytes.len > product_name.len);

    return bytes;
}

fn expect_export_decoded(gpa: Allocator, document: *const json.Document, bytes: []const u8) !void {
    const root = document.root();

    try std.testing.expect(document.kind_of(root) == .array);

    var reader = std.Io.Reader.fixed(bytes);
    var decoder = try Decoder.init(&reader);
    var stream = decode.Stream.init(&decoder, gpa);
    defer stream.deinit();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    var items = document.items(root);
    var count: u32 = 0;

    while (count < message_count_max) : (count += 1) {
        _ = arena_state.reset(.retain_capacity);

        const message = switch (try stream.next(arena_state.allocator())) {
            .end => break,
            .message => |message| message,
        };

        const item = items.next() orelse return error.TestUnexpectedResult;

        try expect_message_exported(document, item, message);
    }

    try std.testing.expect(count > 0);
    try std.testing.expectEqual(count, document.count_of(root));
}

fn expect_message_exported(
    document: *const json.Document,
    node: json.Node,
    message: Message,
) !void {
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

        try expect_integer_exported(i64, document, timestamp, epoch.to_unix_seconds(seconds));
    }

    try std.testing.expect(document.kind_of(fields) == .object);
    try std.testing.expectEqual(message.fields.len, document.count_of(fields));

    var entries = document.entries(fields);

    for (message.fields) |field| {
        const entry = entries.next() orelse return error.TestUnexpectedResult;

        try std.testing.expect(document.text_is(entry.key, field.name));
        try expect_value_exported(document, entry.value, field.value);
    }
}

fn expect_value_exported(document: *const json.Document, node: json.Node, value: Value) !void {
    switch (value) {
        .none => try std.testing.expect(document.kind_of(node) == .null_value),
        .integer => |number| try expect_integer_exported(i64, document, node, number),
        .unsigned => |number| try expect_integer_exported(u64, document, node, number),
        .real => |number| try expect_real_exported(document, node, number),
        .string => |text| try std.testing.expect(document.text_is(node, text)),
        .enumeration => |name| try std.testing.expect(document.text_is(node, name)),
        .bytes => |data| try expect_bytes_exported(document, node, data),
        .integer_array => |numbers| try expect_items_exported(i64, document, node, numbers),
        .real_array => |numbers| try expect_items_exported(f64, document, node, numbers),
    }
}

fn expect_items_exported(
    comptime Number: type,
    document: *const json.Document,
    node: json.Node,
    numbers: []const Number,
) !void {
    try std.testing.expect(document.kind_of(node) == .array);
    try std.testing.expectEqual(numbers.len, document.count_of(node));

    var items = document.items(node);

    for (numbers) |number| {
        const item = items.next() orelse return error.TestUnexpectedResult;

        if (Number == f64) {
            try expect_real_exported(document, item, number);
        } else {
            try expect_integer_exported(Number, document, item, number);
        }
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
    if (std.math.isFinite(number)) {
        try std.testing.expect(document.kind_of(node) == .number);

        const parsed = try std.fmt.parseFloat(f64, document.source_of(node));

        try std.testing.expectEqual(number, parsed);
        try std.testing.expectEqual(std.math.signbit(number), std.math.signbit(parsed));
    } else {
        try std.testing.expect(document.kind_of(node) == .null_value);
    }
}

fn expect_bytes_exported(document: *const json.Document, node: json.Node, data: []const u8) !void {
    try std.testing.expect(document.kind_of(node) == .string);

    var buffer: [Decoder.field_bytes_max]u8 = undefined;
    const text = document.text_of(node) orelse return error.TestUnexpectedResult;
    const decoded = try std.fmt.hexToBytes(&buffer, text);

    try std.testing.expectEqualSlices(u8, data, decoded);
}

test "json export escapes every control byte a fit string can hold" {
    const gpa = std.testing.allocator;

    var product_name: [0x1f]u8 = undefined;

    for (&product_name, 1..) |*byte, code| byte.* = @intCast(code);

    const bytes = try encoded_product_name(gpa, &product_name);
    defer gpa.free(bytes);

    var exported: Writer.Allocating = .init(gpa);
    defer exported.deinit();

    try write_json(&exported.writer, gpa, bytes);

    var document: ExportedDocument = undefined;

    try document.parse(exported.written());

    const field = document.pointer_find(document.root(), "/0/fields/product_name") orelse
        return error.TestUnexpectedResult;

    try std.testing.expect(document.text_is(field, &product_name));
    try expect_export_decoded(gpa, &document.document, bytes);
}

test "json export reads back every value kind as its source value" {
    const gpa = std.testing.allocator;

    var exported: Writer.Allocating = .init(gpa);
    defer exported.deinit();

    try write_message_json(&exported.writer, fixture_message);

    var document: ExportedDocument = undefined;

    try document.parse(exported.written());
    try expect_message_exported(&document.document, document.root(), fixture_message);
}

test "json export writes each byte outside a utf-8 sequence as its code point" {
    const gpa = std.testing.allocator;
    const fields = [_]decode.Field{fixture_field("invalid \xfe", .{ .string = "a\xffb\xc3" })};

    const message: Message = .{
        .global_number = 0,
        .name = "invalid",
        .timestamp = null,
        .fields = &fields,
    };

    var exported: Writer.Allocating = .init(gpa);
    defer exported.deinit();

    try write_message_json(&exported.writer, message);

    var document: ExportedDocument = undefined;

    try document.parse(exported.written());

    const field = document.pointer_find(document.root(), "/fields/invalid \u{fe}") orelse
        return error.TestUnexpectedResult;

    try std.testing.expect(document.text_is(field, "a\u{ff}b\u{c3}"));
}

test "json export reads back each message of a file as its decoded source" {
    const gpa = std.testing.allocator;

    var encoder = Encoder.init(gpa);
    defer encoder.deinit();

    try encoder.message(0, &.{
        .{ .number = 0, .value = .{ .enum_value = 4 } },
        .{ .number = 8, .value = .{ .string = "quote \" backslash \\ caf\u{e9}" } },
    });

    try encoder.message(20, &.{
        .{ .number = 253, .value = .{ .uint32 = 1_000_000_000 } },
        .{ .number = 0, .value = .{ .sint32 = -123_456_789 } },
        .{ .number = 2, .value = .{ .uint16 = 3000 } },
        .{ .number = 3, .value = .{ .uint8 = 0xff } },
        .{ .number = 6, .value = .{ .uint16 = 3050 } },
    });

    var encoded: Writer.Allocating = .init(gpa);
    defer encoded.deinit();

    try encoder.finish(&encoded.writer);

    var exported: Writer.Allocating = .init(gpa);
    defer exported.deinit();

    try write_json(&exported.writer, gpa, encoded.written());

    const written = exported.written();

    try std.testing.expect(std.mem.startsWith(u8, written, "[\n  {\"message\":"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, written, "}},\n  {\"message\":"));
    try std.testing.expect(std.mem.endsWith(u8, written, "}}\n]\n"));
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, written, "\n"));

    var document: ExportedDocument = undefined;

    try document.parse(written);
    try std.testing.expectEqual(@as(u32, 2), document.count_of(document.root()));
    try expect_export_decoded(gpa, &document.document, encoded.written());
}

test "csv export quotes a field that holds a carriage return" {
    const gpa = std.testing.allocator;
    const bytes = try encoded_product_name(gpa, "a\rb");
    defer gpa.free(bytes);

    var exported: Writer.Allocating = .init(gpa);
    defer exported.deinit();

    try write_csv(&exported.writer, gpa, bytes, 0);

    const expected = "timestamp_unix,product_name\n,\"a\rb\"\n";

    try std.testing.expectEqualStrings(expected, exported.written());
}

const std = @import("std");

const Writer = std.Io.Writer;
const assert = std.debug.assert;

pub const Error = Writer.Error;

pub const EnumLiteral = struct {
    name: []const u8,
};

pub const Verbatim = struct {
    text: []const u8,
};

pub const Place = struct {
    column: u32,
    indent: u32,
    trailer: u32,
};

const Kind = enum {
    leaf,
    record,
    records,
    structure,
};

const Inner = struct {
    number: u8,
    flag: bool,
};

const Outer = struct {
    name: []const u8,
    type_id: ?EnumLiteral,
    scale: f64,
    signed: i64,
    items: []const Inner,
    reference: Verbatim,
};

const Wide = struct {
    name: []const u8,
    units: []const u8,
    scale: f64,
};

const Holder = struct {
    label: []const u8,
    wides: []const Wide,
    items: []const Inner,
};

pub const column_count_max: u32 = 100;

const float_marker_bytes = ".eE";
const indent_width: u32 = 4;
const measure_buffer_bytes: u32 = 256;
const member_separator = " = ";
const real_bytes_max: u32 = 32;

comptime {
    assert(real_bytes_max >= 24);
    assert(indent_width == 4);
    assert(column_count_max > indent_width);
    assert(measure_buffer_bytes > 0);
    assert(member_separator.len == 3);
}

const workbook_reals = [_]struct { value: f64, text: []const u8 }{
    .{ .value = -110.0, .text = "-110.0" },
    .{ .value = 0.0, .text = "0.0" },
    .{ .value = 0.7111111, .text = "0.7111111" },
    .{ .value = 1.0, .text = "1.0" },
    .{ .value = 1.024, .text = "1.024" },
    .{ .value = 10.0, .text = "10.0" },
    .{ .value = 100.0, .text = "100.0" },
    .{ .value = 1000.0, .text = "1000.0" },
    .{ .value = 1000000.0, .text = "1000000.0" },
    .{ .value = 1024.0, .text = "1024.0" },
    .{ .value = 10430.38, .text = "10430.38" },
    .{ .value = 128.0, .text = "128.0" },
    .{ .value = 16.0, .text = "16.0" },
    .{ .value = 2.0, .text = "2.0" },
    .{ .value = 25.0, .text = "25.0" },
    .{ .value = 256.0, .text = "256.0" },
    .{ .value = 28.57143, .text = "28.57143" },
    .{ .value = 32768.0, .text = "32768.0" },
    .{ .value = 4.0, .text = "4.0" },
    .{ .value = 5.0, .text = "5.0" },
    .{ .value = 500.0, .text = "500.0" },
    .{ .value = 5000.0, .text = "5000.0" },
    .{ .value = 65535.0, .text = "65535.0" },
    .{ .value = 65536.0, .text = "65536.0" },
};

pub fn value(writer: *Writer, data: anytype) Error!void {
    comptime assert(@TypeOf(data) != void);
    assert(writer.buffer.len > 0);

    return switch (comptime kind_of(@TypeOf(data))) {
        .leaf => leaf(writer, data),
        .record => record(writer, data),
        .records => records(writer, data),
        .structure => structure(writer, data),
    };
}

pub fn wrapped(writer: *Writer, data: anytype, place: Place) Error!void {
    comptime assert(!is_leaf(@TypeOf(data)));
    assert(place.indent <= place.column);
    assert(place.column < column_count_max);

    return switch (comptime kind_of(@TypeOf(data))) {
        .record => record_wrapped(writer, data, place),
        .structure => structure_wrapped(writer, data, place),
        .leaf, .records => @compileError("only a struct literal wraps at the top level"),
    };
}

pub fn real(writer: *Writer, number: f64) Error!void {
    assert(std.math.isFinite(number));

    var buffer: [real_bytes_max]u8 = undefined;

    const text = std.mem.print(&buffer, "{d}", .{number}) catch |err| switch (err) {
        error.NoSpaceLeft => @panic("real_bytes_max too small for an f64 literal"),
    };

    assert(text.len > 0);
    assert(text.len <= real_bytes_max);

    try writer.writeAll(text);

    if (std.mem.findAny(u8, text, float_marker_bytes) == null) {
        try writer.writeAll(".0");
    }
}

fn kind_of(comptime Data: type) Kind {
    if (is_leaf(Data)) return .leaf;
    if (is_records(Data)) return .records;
    if (is_record(Data)) return .record;
    if (is_structure(Data)) return .structure;

    @compileError("no Zig literal for " ++ @typeName(Data));
}

fn is_scalar(comptime Data: type) bool {
    if (Data == EnumLiteral) return true;
    if (Data == Verbatim) return true;
    if (Data == []const u8) return true;

    return switch (@typeInfo(Data)) {
        .bool, .int, .float => true,
        else => false,
    };
}

fn is_leaf(comptime Data: type) bool {
    return switch (@typeInfo(Data)) {
        .optional => |optional| is_scalar(optional.child),
        else => is_scalar(Data),
    };
}

fn is_record(comptime Data: type) bool {
    if (is_scalar(Data)) return false;
    if (@typeInfo(Data) != .@"struct") return false;

    const fields = @typeInfo(Data).@"struct";
    if (fields.layout != .auto) return false;
    if (fields.field_names.len == 0) return false;

    for (fields.field_types) |Field| {
        if (!is_leaf(Field)) return false;
    }

    return true;
}

fn is_records(comptime Data: type) bool {
    if (Data == []const u8) return false;

    return switch (@typeInfo(Data)) {
        .pointer => |pointer| pointer.size == .slice and is_record(pointer.child),
        else => false,
    };
}

fn is_structure(comptime Data: type) bool {
    if (is_scalar(Data)) return false;
    if (@typeInfo(Data) != .@"struct") return false;

    const fields = @typeInfo(Data).@"struct";
    if (fields.layout != .auto) return false;
    if (fields.field_names.len == 0) return false;

    for (fields.field_types) |Field| {
        if (!is_leaf(Field)) {
            if (!is_records(Field)) return false;
        }
    }

    return true;
}

fn leaf(writer: *Writer, data: anytype) Error!void {
    comptime assert(is_leaf(@TypeOf(data)));
    assert(writer.buffer.len > 0);

    switch (@typeInfo(@TypeOf(data))) {
        .optional => {
            const present = data orelse return writer.writeAll("null");
            return scalar(writer, present);
        },
        else => return scalar(writer, data),
    }
}

fn scalar(writer: *Writer, data: anytype) Error!void {
    comptime assert(is_scalar(@TypeOf(data)));
    assert(writer.buffer.len > 0);

    const Data = @TypeOf(data);

    if (Data == EnumLiteral) return writer.print(".{f}", .{std.zig.fmtId(data.name)});
    if (Data == Verbatim) return writer.writeAll(data.text);
    if (Data == []const u8) return writer.print("\"{f}\"", .{std.zig.fmtString(data)});

    return switch (@typeInfo(Data)) {
        .bool => writer.writeAll(if (data) "true" else "false"),
        .int => writer.print("{d}", .{data}),
        .float => real(writer, data),
        else => @compileError("no scalar literal for " ++ @typeName(Data)),
    };
}

fn record(writer: *Writer, data: anytype) Error!void {
    comptime assert(is_record(@TypeOf(data)));
    assert(writer.buffer.len > 0);

    const field_names = @typeInfo(@TypeOf(data)).@"struct".field_names;

    comptime assert(field_names.len > 0);

    try writer.writeAll(".{ ");

    inline for (field_names, 0..) |field_name, index| {
        if (index > 0) try writer.writeAll(", ");

        try writer.print(".{s}{s}", .{ field_name, member_separator });
        try leaf(writer, @field(data, field_name));
    }

    try writer.writeAll(" }");
}

fn records(writer: *Writer, items: anytype) Error!void {
    comptime assert(is_records(@TypeOf(items)));
    assert(writer.buffer.len > 0);

    if (items.len == 0) return writer.writeAll("&.{}");

    const tight = items.len == 1;

    try writer.writeAll(if (tight) "&.{" else "&.{ ");

    for (items, 0..) |item, index| {
        if (index > 0) try writer.writeAll(", ");

        try record(writer, item);
    }

    try writer.writeAll(if (tight) "}" else " }");
}

fn structure(writer: *Writer, data: anytype) Error!void {
    comptime assert(is_structure(@TypeOf(data)));
    assert(writer.buffer.len > 0);

    const field_names = @typeInfo(@TypeOf(data)).@"struct".field_names;

    comptime assert(field_names.len > 0);

    try writer.writeAll(".{ ");

    inline for (field_names, 0..) |field_name, index| {
        if (index > 0) try writer.writeAll(", ");

        try writer.print(".{s}{s}", .{ field_name, member_separator });
        try member(writer, @field(data, field_name));
    }

    try writer.writeAll(" }");
}

fn member(writer: *Writer, data: anytype) Error!void {
    comptime assert(!is_record(@TypeOf(data)));
    comptime assert(!is_structure(@TypeOf(data)));

    return switch (comptime kind_of(@TypeOf(data))) {
        .leaf => leaf(writer, data),
        .records => records(writer, data),
        .record, .structure => @compileError("a member is a leaf or a slice of records"),
    };
}

fn fits(data: anytype, place: Place) Error!bool {
    comptime assert(!is_leaf(@TypeOf(data)));
    assert(place.indent <= place.column);

    var buffer: [measure_buffer_bytes]u8 = undefined;
    var discarding: Writer.Discarding = .init(&buffer);

    try value(&discarding.writer, data);

    const width = discarding.fullCount();

    assert(width > 0);

    return place.column + width + place.trailer <= column_count_max;
}

fn record_wrapped(writer: *Writer, data: anytype, place: Place) Error!void {
    comptime assert(is_record(@TypeOf(data)));
    assert(place.indent <= place.column);

    const field_names = @typeInfo(@TypeOf(data)).@"struct".field_names;

    if (try fits(data, place)) return record(writer, data);

    const inner = place.indent + indent_width;

    assert(inner < column_count_max);

    try writer.writeAll(".{\n");

    inline for (field_names) |field_name| {
        try writer.splatByteAll(' ', inner);
        try writer.print(".{s}{s}", .{ field_name, member_separator });
        try leaf(writer, @field(data, field_name));
        try writer.writeAll(",\n");
    }

    try writer.splatByteAll(' ', place.indent);
    try writer.writeByte('}');
}

fn structure_wrapped(writer: *Writer, data: anytype, place: Place) Error!void {
    comptime assert(is_structure(@TypeOf(data)));
    assert(place.indent <= place.column);

    const field_names = @typeInfo(@TypeOf(data)).@"struct".field_names;

    if (try fits(data, place)) return structure(writer, data);

    const inner = place.indent + indent_width;

    assert(inner < column_count_max);

    try writer.writeAll(".{\n");

    inline for (field_names) |field_name| {
        const column = inner + 1 + field_name.len + member_separator.len;

        try writer.splatByteAll(' ', inner);
        try writer.print(".{s}{s}", .{ field_name, member_separator });

        try member_wrapped(writer, @field(data, field_name), .{
            .column = @intCast(column),
            .indent = inner,
            .trailer = 1,
        });

        try writer.writeAll(",\n");
    }

    try writer.splatByteAll(' ', place.indent);
    try writer.writeByte('}');
}

fn member_wrapped(writer: *Writer, data: anytype, place: Place) Error!void {
    comptime assert(!is_record(@TypeOf(data)));
    assert(place.indent <= place.column);

    return switch (comptime kind_of(@TypeOf(data))) {
        .leaf => leaf(writer, data),
        .records => records_wrapped(writer, data, place),
        .record, .structure => @compileError("a member is a leaf or a slice of records"),
    };
}

fn records_wrapped(writer: *Writer, items: anytype, place: Place) Error!void {
    comptime assert(is_records(@TypeOf(items)));
    assert(place.indent <= place.column);

    if (items.len == 0) return records(writer, items);
    if (try fits(items, place)) return records(writer, items);

    const inner = place.indent + indent_width;

    assert(inner < column_count_max);
    assert(items.len > 0);

    try writer.writeAll("&.{\n");

    for (items) |item| {
        try writer.splatByteAll(' ', inner);
        try record_wrapped(writer, item, .{ .column = inner, .indent = inner, .trailer = 1 });
        try writer.writeAll(",\n");
    }

    try writer.splatByteAll(' ', place.indent);
    try writer.writeByte('}');
}

fn rendered(buffer: []u8, data: anytype) ![]const u8 {
    comptime assert(@TypeOf(data) != void);
    assert(buffer.len > 0);

    var out: Writer = .fixed(buffer);

    try value(&out, data);

    return out.buffered();
}

test "a struct renders as a literal with its fields in declaration order" {
    var buffer: [512]u8 = undefined;

    const data = Outer{
        .name = "speed",
        .type_id = .{ .name = "file" },
        .scale = 1000.0,
        .signed = -2,
        .items = &.{ .{ .number = 1, .flag = true }, .{ .number = 2, .flag = false } },
        .reference = .{ .text = "&record_fields" },
    };

    try std.testing.expectEqualStrings(
        ".{ .name = \"speed\", .type_id = .file, .scale = 1000.0, .signed = -2, " ++
            ".items = &.{ .{ .number = 1, .flag = true }, .{ .number = 2, .flag = false } }, " ++
            ".reference = &record_fields }",
        try rendered(&buffer, data),
    );
}

test "an absent optional renders as null" {
    var buffer: [64]u8 = undefined;

    try std.testing.expectEqualStrings("null", try rendered(&buffer, @as(?EnumLiteral, null)));
    try std.testing.expectEqualStrings("null", try rendered(&buffer, @as(?u8, null)));
    try std.testing.expectEqualStrings("7", try rendered(&buffer, @as(?u8, 7)));
}

test "a slice renders tight when it holds one element" {
    var buffer: [256]u8 = undefined;

    const empty: []const Inner = &.{};
    const one: []const Inner = &.{.{ .number = 3, .flag = false }};

    const two: []const Inner = &.{
        .{ .number = 3, .flag = false },
        .{ .number = 4, .flag = true },
    };

    try std.testing.expectEqualStrings("&.{}", try rendered(&buffer, empty));

    try std.testing.expectEqualStrings(
        "&.{.{ .number = 3, .flag = false }}",
        try rendered(&buffer, one),
    );

    try std.testing.expectEqualStrings(
        "&.{ .{ .number = 3, .flag = false }, .{ .number = 4, .flag = true } }",
        try rendered(&buffer, two),
    );
}

test "an enum literal is quoted only when it has to be" {
    var buffer: [64]u8 = undefined;

    const Case = struct { name: []const u8, literal: []const u8 };

    const cases = [_]Case{
        .{ .name = "record", .literal = ".record" },
        .{ .name = "mesg_num", .literal = ".mesg_num" },
        .{ .name = "switch", .literal = ".@\"switch\"" },
        .{ .name = "u8", .literal = ".@\"u8\"" },
        .{ .name = "4iiii", .literal = ".@\"4iiii\"" },
    };

    for (cases) |case| {
        const literal = try rendered(&buffer, EnumLiteral{ .name = case.name });

        try std.testing.expectEqualStrings(case.literal, literal);
    }
}

test "strings are quoted and escaped" {
    var buffer: [64]u8 = undefined;

    try std.testing.expectEqualStrings("\"\"", try rendered(&buffer, @as([]const u8, "")));
    try std.testing.expectEqualStrings("\"m/s\"", try rendered(&buffer, @as([]const u8, "m/s")));
    const quote = try rendered(&buffer, @as([]const u8, "a\"b"));

    try std.testing.expectEqualStrings("\"a\\\"b\"", quote);

    const backslash = try rendered(&buffer, @as([]const u8, "a\\b"));

    try std.testing.expectEqualStrings("\"a\\\\b\"", backslash);
    try std.testing.expectEqualStrings("\"a\\nb\"", try rendered(&buffer, @as([]const u8, "a\nb")));
}

test real {
    var buffer: [64]u8 = undefined;

    for (workbook_reals) |expected| {
        const text = try rendered(&buffer, expected.value);

        try std.testing.expectEqualStrings(expected.text, text);
        try std.testing.expectEqual(expected.value, try std.fmt.parseFloat(f64, text));
    }

    try std.testing.expectEqualStrings("7.0", try rendered(&buffer, @as(f64, 7.0)));
    try std.testing.expectEqualStrings("-7.0", try rendered(&buffer, @as(f64, -7.0)));
    try std.testing.expectEqualStrings("0.5", try rendered(&buffer, @as(f64, 0.5)));
}

fn wrapped_source(buffer: []u8, data: anytype) ![:0]const u8 {
    comptime assert(!is_leaf(@TypeOf(data)));
    assert(buffer.len > 1);

    const prefix = "const literal = ";

    var out: Writer = .fixed(buffer[0 .. buffer.len - 1]);

    try out.writeAll(prefix);
    try wrapped(&out, data, .{ .column = prefix.len, .indent = 0, .trailer = 1 });
    try out.writeAll(";\n");

    const length = out.buffered().len;

    buffer[length] = 0;

    return buffer[0..length :0];
}

fn formatted_expect(source: [:0]const u8) !void {
    assert(source.len > 0);
    assert(source[source.len - 1] == '\n');

    const gpa = std.testing.allocator;

    var tree = try std.zig.Ast.parse(gpa, source, .{ .mode = .zig });
    defer tree.deinit(gpa);

    const rendered_source = try tree.renderAlloc(gpa);
    defer gpa.free(rendered_source);

    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
    try std.testing.expectEqualStrings(source, rendered_source);

    var lines = std.mem.splitScalar(u8, source, '\n');

    for (0..source.len + 1) |_| {
        const line = lines.next() orelse break;

        try std.testing.expect(line.len <= column_count_max);
    }
}

test wrapped {
    var buffer: [256]u8 = undefined;

    const data = Inner{ .number = 3, .flag = false };
    const source = try wrapped_source(&buffer, data);

    try std.testing.expectEqualStrings(
        "const literal = .{ .number = 3, .flag = false };\n",
        source,
    );

    try formatted_expect(source);
}

test "a literal too wide for one line wraps one member per line as zig fmt does" {
    var buffer: [2048]u8 = undefined;
    var collapsed_buffer: [2048]u8 = undefined;

    const data = Holder{
        .label = "a label long enough to push the whole literal past the limit",
        .wides = &.{
            .{
                .name = "a field name of forty characters exactly",
                .units = "units that are also forty characters long",
                .scale = 1000.0,
            },
            .{ .name = "short", .units = "m", .scale = 1.0 },
        },
        .items = &.{.{ .number = 1, .flag = true }},
    };

    const source = try wrapped_source(&buffer, data);

    try formatted_expect(source);
    try std.testing.expect(std.mem.count(u8, source, "\n") > 1);

    const single = try rendered(&collapsed_buffer, data);

    try std.testing.expect(single.len > column_count_max);
    try std.testing.expect(std.mem.find(u8, source, "\"short\"") != null);
}

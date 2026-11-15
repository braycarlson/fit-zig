const std = @import("std");

const model_module = @import("model.zig");
const render = @import("render.zig");
const sheets = @import("sheets.zig");

const Writer = std.Io.Writer;
const assert = std.debug.assert;

const Message = model_module.Message;
const Model = model_module.Model;
const NamedValue = sheets.NamedValue;

pub const Error = Writer.Error || error{ValuesExhausted};

const MessageLiteral = struct {
    global_number: u16,
    name: []const u8,
    fields: render.Verbatim,
};

const TypeValueLiteral = struct {
    type_index: u16,
    value: u64,
    name: []const u8,
};

const element_indent: u32 = 4;
const fields_prefix = "fields_";
const profile_import = "const profile = @import(\"../profile.zig\");\n\n";
const reference_bytes_max: u32 = 32;

const element_place: render.Place = .{
    .column = element_indent,
    .indent = element_indent,
    .trailer = 1,
};

comptime {
    assert(element_indent == 4);
    assert(element_place.column < render.column_count_max);
}

pub fn types_write(writer: *Writer, model: *const Model, scratch: []NamedValue) Error!void {
    assert(model.types.count > 0);
    assert(scratch.len > 0);

    try writer.writeAll(profile_import);
    try writer.writeAll("pub const type_names = [_][]const u8{\n");

    for (model.types.slice()) |table| {
        assert(table.name.len > 0);

        try writer.print("    \"{f}\",\n", .{std.zig.fmtString(table.name)});
    }

    try writer.writeAll("};\n\n");
    try writer.writeAll("pub const type_values = [_]profile.TypeValue{\n");

    for (model.types.slice(), 0..) |table, type_index| {
        if (table.values.len > scratch.len) return error.ValuesExhausted;

        const values = scratch[0..table.values.len];

        @memcpy(values, table.values);
        std.mem.sort(NamedValue, values, {}, number_less_than);

        for (values) |named| {
            assert(named.name.len > 0);
            assert(named.number >= 0);

            const literal: TypeValueLiteral = .{
                .type_index = @intCast(type_index),
                .value = @intCast(named.number),
                .name = named.name,
            };

            try writer.writeAll("    ");
            try render.wrapped(writer, literal, element_place);
            try writer.writeAll(",\n");
        }
    }

    try writer.writeAll("};\n");
}

pub fn messages_write(writer: *Writer, model: *const Model) Error!void {
    assert(model.messages.count > 0);
    assert(model.fields.count > 0);

    try writer.writeAll(profile_import);

    for (model.messages.slice()) |*message| try field_table_write(writer, message);

    try writer.writeAll("pub const messages = [_]profile.Message{\n");

    for (model.messages.slice()) |*message| {
        assert(message.name.len > 0);

        var buffer: [reference_bytes_max]u8 = undefined;

        const reference = std.mem.print(&buffer, "&{s}{d}", .{
            fields_prefix,
            message.global_number,
        }) catch |err| switch (err) {
            error.NoSpaceLeft => unreachable,
        };

        const literal: MessageLiteral = .{
            .global_number = message.global_number,
            .name = message.name,
            .fields = .{ .text = reference },
        };

        try writer.writeAll("    ");
        try render.wrapped(writer, literal, element_place);
        try writer.writeAll(",\n");
    }

    try writer.writeAll("};\n");
}

fn field_table_write(writer: *Writer, message: *const Message) Writer.Error!void {
    assert(message.name.len > 0);
    assert(message.fields.len <= std.math.maxInt(u8) + 1);

    try writer.print("const {s}{d} = [_]profile.Field{{\n", .{
        fields_prefix,
        message.global_number,
    });

    for (message.fields) |field| {
        assert(field.name.len > 0);
        assert(field.scale != 0.0);

        try writer.writeAll("    ");
        try render.wrapped(writer, field, element_place);
        try writer.writeAll(",\n");
    }

    try writer.writeAll("};\n\n");
}

fn number_less_than(_: void, left: NamedValue, right: NamedValue) bool {
    assert(left.name.len > 0);
    assert(right.name.len > 0);

    return left.number < right.number;
}

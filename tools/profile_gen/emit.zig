const std = @import("std");

const model = @import("model.zig");
const render = @import("render.zig");
const sheets = @import("sheets.zig");

const Allocator = std.mem.Allocator;
const Message = model.Message;
const Model = model.Model;
const NamedValue = sheets.NamedValue;
const Writer = std.Io.Writer;
const assert = std.debug.assert;

pub const Error = Allocator.Error || render.Error;

const MessageInfoLiteral = struct {
    global_number: u16,
    name: []const u8,
    fields: render.Verbatim,
};

const TypeValueLiteral = struct {
    type_id: render.EnumLiteral,
    value: u64,
    name: []const u8,
};

const profile_import = "profile";
const fields_prefix = "fields_";
const element_indent = 4;
const validation_branch_quota = 1_000_000;

const element_place: render.Place = .{
    .column = element_indent,
    .indent = element_indent,
    .trailer = 1,
};

const type_value_declarations =
    \\const TypeValue = struct {
    \\    type_id: TypeId,
    \\    value: u64,
    \\    name: []const u8,
    \\};
    \\
    \\const TypeValueKey = struct {
    \\    type_id: TypeId,
    \\    value: u64,
    \\};
    \\
    \\
;

const type_value_lookup =
    \\pub fn type_value_name(type_id: TypeId, value: u64) ?[]const u8 {
    \\    const key: TypeValueKey = .{ .type_id = type_id, .value = value };
    \\    const found = std.sort.binarySearch(TypeValue, &type_values, key, type_value_order);
    \\    const index = found orelse return null;
    \\
    \\    assert(type_values[index].type_id == type_id);
    \\    assert(type_values[index].value == value);
    \\
    \\    return type_values[index].name;
    \\}
    \\
    \\fn type_value_order(key: TypeValueKey, item: TypeValue) std.math.Order {
    \\    const key_rank = @backingInt(key.type_id);
    \\    const item_rank = @backingInt(item.type_id);
    \\    if (key_rank != item_rank) return std.math.order(key_rank, item_rank);
    \\    return std.math.order(key.value, item.value);
    \\}
    \\
;

const type_value_validation =
    \\    assert(type_values.len > 0);
    \\
    \\    for (type_values[1..], type_values[0 .. type_values.len - 1]) |item, previous| {
    \\        const key: TypeValueKey = .{ .type_id = previous.type_id, .value = previous.value };
    \\
    \\        assert(item.name.len > 0);
    \\        assert(type_value_order(key, item) == .lt);
    \\    }
    \\}
    \\
;

const message_lookup =
    \\pub fn message_info(global_number: u16) ?*const profile.MessageInfo {
    \\    for (&message_infos) |*info| {
    \\        if (info.global_number == global_number) return info;
    \\    }
    \\
    \\    return null;
    \\}
    \\
;

const message_validation =
    \\    for (&message_infos) |info| {
    \\        assert(info.name.len > 0);
    \\        assert(message_info(info.global_number).?.global_number == info.global_number);
    \\
    \\        for (info.fields) |field| {
    \\            assert(field.name.len > 0);
    \\            assert(field.scale != 0.0);
    \\            assert(std.math.isFinite(field.scale));
    \\            assert(std.math.isFinite(field.offset));
    \\
    \\            for (field.subfields) |subfield| {
    \\                assert(subfield.name.len > 0);
    \\                assert(subfield.scale != 0.0);
    \\                assert(subfield.reference_value >= 0);
    \\            }
    \\
    \\            for (field.components) |component| {
    \\                assert(component.scale != 0.0);
    \\                assert(std.math.isFinite(component.offset));
    \\            }
    \\        }
    \\    }
    \\}
    \\
;

comptime {
    assert(profile_import.len > 0);
    assert(fields_prefix.len > 0);
    assert(element_indent == 4);
    assert(element_place.column < render.column_count_max);
}

pub fn types_file(arena: Allocator, profile: *const Model) Error![]const u8 {
    assert(profile.types.len > 0);

    var out: Writer.Allocating = .init(arena);
    const writer = &out.writer;

    try writer.writeAll("const std = @import(\"std\");\n\n");
    try writer.writeAll("const assert = std.debug.assert;\n\n");
    try writer.writeAll("pub const TypeId = enum {\n");

    for (profile.types) |table| {
        assert(table.name.len > 0);

        try writer.print("    {f},\n", .{std.zig.fmtId(table.name)});
    }

    try writer.writeAll("};\n\n");
    try writer.writeAll(type_value_declarations);
    try write_type_values(arena, writer, profile.types);
    try writer.writeAll(type_value_lookup);
    try write_validation(writer, type_value_validation);

    assert(out.writer.buffered().len > 0);

    return out.writer.buffered();
}

fn write_type_values(
    arena: Allocator,
    writer: *Writer,
    tables: []const model.TypeTable,
) Error!void {
    assert(tables.len > 0);

    try writer.writeAll("const type_values = [_]TypeValue{\n");

    for (tables) |table| {
        assert(table.name.len > 0);
        assert(table.values.len > 0);

        const values = try arena.dupe(NamedValue, table.values);

        std.mem.sort(NamedValue, values, {}, number_less_than);

        for (values) |named| {
            assert(named.name.len > 0);
            assert(named.number >= 0);

            const literal = TypeValueLiteral{
                .type_id = .{ .name = table.name },
                .value = @intCast(named.number),
                .name = named.name,
            };

            try writer.writeAll("    ");
            try render.wrapped(writer, literal, element_place);
            try writer.writeAll(",\n");
        }
    }

    try writer.writeAll("};\n\n");
}

fn number_less_than(_: void, left: NamedValue, right: NamedValue) bool {
    return left.number < right.number;
}

pub fn messages_file(arena: Allocator, profile: *const Model) Error![]const u8 {
    assert(profile.messages.len > 0);

    var out: Writer.Allocating = .init(arena);
    const writer = &out.writer;

    try writer.writeAll("const std = @import(\"std\");\n\n");
    try writer.print("const {s} = @import(\"../profile.zig\");\n", .{profile_import});
    try writer.writeAll("const BaseType = @import(\"../decoder.zig\").BaseType;\n");
    try writer.writeAll("const TypeId = @import(\"types.zig\").TypeId;\n\n");
    try writer.writeAll("const assert = std.debug.assert;\n\n");

    for (profile.messages) |message| {
        try write_field_table(writer, message);
    }

    try write_infos_table(arena, writer, profile.messages);
    try writer.writeAll(message_lookup);
    try write_validation(writer, message_validation);

    assert(out.writer.buffered().len > 0);

    return out.writer.buffered();
}

fn write_field_table(writer: *Writer, message: Message) Error!void {
    assert(message.name.len > 0);

    try writer.print("const {s}{s} = [_]{s}.FieldInfo{{\n", .{
        fields_prefix,
        message.name,
        profile_import,
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

fn write_infos_table(arena: Allocator, writer: *Writer, messages: []const Message) Error!void {
    assert(messages.len > 0);

    try writer.print("const message_infos = [_]{s}.MessageInfo{{\n", .{profile_import});

    for (messages) |message| {
        assert(message.name.len > 0);

        const reference = try arena.print("&{s}{s}", .{ fields_prefix, message.name });

        assert(reference.len == message.name.len + fields_prefix.len + 1);
        assert(reference[0] == '&');

        const literal = MessageInfoLiteral{
            .global_number = message.global_number,
            .name = message.name,
            .fields = .{ .text = reference },
        };

        try writer.writeAll("    ");
        try render.wrapped(writer, literal, element_place);
        try writer.writeAll(",\n");
    }

    try writer.writeAll("};\n\n");
}

fn write_validation(writer: *Writer, body: []const u8) Error!void {
    assert(body.len > 0);
    assert(body[body.len - 1] == '\n');

    try writer.print("\ncomptime {{\n    @setEvalBranchQuota({d});\n\n", .{
        validation_branch_quota,
    });

    try writer.writeAll(body);
}

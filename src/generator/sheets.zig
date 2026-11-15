const std = @import("std");

const bounded = @import("bounded");

const xlsx = @import("xlsx.zig");

const Row = xlsx.Row;
const assert = std.debug.assert;

pub const CapacityError = error{
    FieldsExhausted,
    ListsExhausted,
    MessagesExhausted,
    RowsExhausted,
    SubfieldsExhausted,
    TypesExhausted,
    ValuesExhausted,
};

pub const Error = CapacityError || error{
    FieldNumberInvalid,
    TypeDuplicate,
};

pub const FieldRow = struct {
    accumulate: []const []const u8,
    array: []const u8,
    bits: []const []const u8,
    components: []const []const u8,
    fit_type: []const u8,
    name: []const u8,
    number: ?u8,
    offset: []const []const u8,
    reference_fields: []const []const u8,
    reference_values: []const []const u8,
    scale: []const []const u8,
    subfields: []const FieldRow,
    units: []const []const u8,
};

pub const MessageDefinition = struct {
    fields: []const FieldRow,
    name: []const u8,

    pub fn field_named(message: *const MessageDefinition, name: []const u8) ?*const FieldRow {
        assert(message.name.len > 0);

        if (name.len == 0) return null;

        var result: ?*const FieldRow = null;

        for (message.fields) |*field| {
            if (std.mem.eql(u8, field.name, name)) result = field;
        }

        return result;
    }
};

pub const NamedValue = struct {
    name: []const u8,
    number: i64,
};

pub const TypeDefinition = struct {
    base: []const u8,
    name: []const u8,
    values: []const NamedValue,

    pub fn value_of(definition: *const TypeDefinition, name: []const u8) ?i64 {
        assert(definition.name.len > 0);

        if (name.len == 0) return null;

        for (definition.values) |value| {
            if (std.mem.eql(u8, value.name, name)) return value.number;
        }

        return null;
    }
};

pub const MessageColumn = enum(u8) {
    message_name = 0,
    field_number = 1,
    field_name = 2,
    field_type = 3,
    array = 4,
    components = 5,
    scale = 6,
    offset = 7,
    units = 8,
    bits = 9,
    accumulate = 10,
    reference_field_name = 11,
    reference_field_value = 12,
};

pub const TypeColumn = enum(u8) {
    type_name = 0,
    base_type = 1,
    value_name = 2,
    value = 3,
};

const ParsedRow = struct {
    field: FieldRow,
    numbered: bool,
};

pub const Sheets = struct {
    fields: bounded.ArrayType(FieldRow, field_count_max),
    lists: bounded.ArrayType([]const u8, list_item_count_max),
    message_open: bool,
    messages: bounded.ArrayType(MessageDefinition, message_count_max),
    pending: bounded.ArrayType(ParsedRow, pending_count_max),
    subfields: bounded.ArrayType(FieldRow, subfield_count_max),
    types: bounded.ArrayType(TypeDefinition, type_count_max),
    values: bounded.ArrayType(NamedValue, value_count_max),

    pub fn init(sheets: *Sheets) void {
        assert(field_count_max > 0);
        assert(type_count_max > 0);

        sheets.fields = .empty;
        sheets.lists = .empty;
        sheets.message_open = false;
        sheets.messages = .empty;
        sheets.pending = .empty;
        sheets.subfields = .empty;
        sheets.types = .empty;
        sheets.values = .empty;
    }

    pub fn type_row_take(sheets: *Sheets, row: Row) Error!void {
        assert(row.len <= xlsx.row_cells_max);
        assert(sheets.types.count <= type_count_max);

        const type_name = type_cell(row, .type_name);

        if (type_name.len > 0) {
            if (sheets.type_named(type_name) != null) return error.TypeDuplicate;
            if (sheets.types.full()) return error.TypesExhausted;

            sheets.types.push_slot_assume_capacity().* = .{
                .base = type_cell(row, .base_type),
                .name = type_name,
                .values = sheets.values.slice()[sheets.values.count..],
            };

            return;
        }

        if (sheets.types.count == 0) return;

        try sheets.value_take(row);
    }

    pub fn message_row_take(sheets: *Sheets, row: Row) Error!void {
        assert(row.len <= xlsx.row_cells_max);
        assert(sheets.messages.count <= message_count_max);

        const message_name = message_cell(row, .message_name);

        if (message_name.len > 0) {
            try sheets.messages_finish();

            if (sheets.messages.full()) return error.MessagesExhausted;

            sheets.messages.push_slot_assume_capacity().* = .{
                .fields = &.{},
                .name = message_name,
            };

            sheets.message_open = true;

            return;
        }

        if (!sheets.message_open) return;
        if (message_cell(row, .field_name).len == 0) return;
        if (sheets.pending.full()) return error.RowsExhausted;

        sheets.pending.push_slot_assume_capacity().* = try sheets.field_row_parse(row);
    }

    pub fn messages_finish(sheets: *Sheets) Error!void {
        assert(sheets.pending.count <= pending_count_max);

        if (!sheets.message_open) {
            assert(sheets.pending.count == 0);

            return;
        }

        const message = sheets.messages.get_mutable(sheets.messages.count - 1);
        const start = sheets.fields.count;
        const parsed = sheets.pending.slice();

        var index: u32 = 0;

        for (0..parsed.len + 1) |_| {
            if (index == parsed.len) break;

            const row = parsed[index];

            index += 1;

            if (!row.numbered) continue;

            const subfield_start = sheets.subfields.count;

            for (parsed[index..]) |subfield| {
                if (subfield.numbered) break;
                if (sheets.subfields.full()) return error.SubfieldsExhausted;

                sheets.subfields.push_slot_assume_capacity().* = subfield.field;
                index += 1;
            }

            if (sheets.fields.full()) return error.FieldsExhausted;

            var field = row.field;

            field.subfields = sheets.subfields.slice()[subfield_start..];
            sheets.fields.push_slot_assume_capacity().* = field;
        }

        message.fields = sheets.fields.slice()[start..];
        sheets.pending.clear();
        sheets.message_open = false;

        assert(message.fields.len <= parsed.len);
    }

    pub fn type_named(sheets: *const Sheets, name: []const u8) ?*const TypeDefinition {
        assert(sheets.types.count <= type_count_max);

        if (name.len == 0) return null;

        for (sheets.types.slice()) |*definition| {
            if (std.mem.eql(u8, definition.name, name)) return definition;
        }

        return null;
    }

    pub fn global_number(sheets: *const Sheets, name: []const u8) ?i64 {
        assert(sheets.types.count <= type_count_max);

        if (name.len == 0) return null;

        const numbers = sheets.type_named(message_number_type) orelse return null;

        var result: ?i64 = null;

        for (numbers.values) |value| {
            if (std.mem.eql(u8, value.name, name)) result = value.number;
        }

        if (result) |number| assert(number >= 0);

        return result;
    }

    pub fn type_id_of(sheets: *const Sheets, fit_type: []const u8) ?[]const u8 {
        assert(fit_type.len <= cell_bytes_max);
        assert(sheets.types.count <= type_count_max);

        const definition = sheets.type_named(fit_type) orelse return null;
        if (definition.values.len == 0) return null;
        return definition.name;
    }

    pub fn base_type_of(sheets: *const Sheets, fit_type: []const u8) ?[]const u8 {
        assert(fit_type.len <= cell_bytes_max);
        assert(sheets.types.count <= type_count_max);

        if (base_type_find(fit_type)) |base| return base;

        const definition = sheets.type_named(fit_type) orelse return null;
        return base_type_find(definition.base);
    }

    pub fn value_of(sheets: *const Sheets, reference: *const FieldRow, text: []const u8) ?i64 {
        assert(reference.name.len > 0);
        assert(text.len <= cell_bytes_max);

        if (text.len == 0) return null;
        if (int_parse(text)) |literal| return literal;

        const definition = sheets.type_named(reference.fit_type) orelse return null;
        return definition.value_of(text);
    }

    fn value_take(sheets: *Sheets, row: Row) CapacityError!void {
        assert(sheets.types.count > 0);
        assert(row.len <= xlsx.row_cells_max);

        const value_name = type_cell(row, .value_name);
        const value_text = type_cell(row, .value);

        if (value_name.len == 0) return;
        if (value_text.len == 0) return;

        const number = int_parse(value_text) orelse return;
        if (number < 0) return;

        const current = sheets.types.get_mutable(sheets.types.count - 1);

        for (current.values) |existing| {
            if (existing.number == number) return;
        }

        if (sheets.values.full()) return error.ValuesExhausted;

        const start = sheets.values.count - current.values.len;

        sheets.values.push_slot_assume_capacity().* = .{ .name = value_name, .number = number };
        current.values = sheets.values.slice()[start..];

        assert(current.values[current.values.len - 1].number == number);
    }

    fn field_row_parse(sheets: *Sheets, row: Row) Error!ParsedRow {
        assert(message_cell(row, .field_name).len > 0);
        assert(row.len <= xlsx.row_cells_max);

        const number_text = message_cell(row, .field_number);

        const field: FieldRow = .{
            .accumulate = try sheets.list_split(message_cell(row, .accumulate)),
            .array = message_cell(row, .array),
            .bits = try sheets.list_split(message_cell(row, .bits)),
            .components = try sheets.list_split(message_cell(row, .components)),
            .fit_type = message_cell(row, .field_type),
            .name = message_cell(row, .field_name),
            .number = if (number_text.len > 0) try field_number_parse(number_text) else null,
            .offset = try sheets.list_split(message_cell(row, .offset)),
            .reference_fields = try sheets.list_split(message_cell(row, .reference_field_name)),
            .reference_values = try sheets.list_split(message_cell(row, .reference_field_value)),
            .scale = try sheets.list_split(message_cell(row, .scale)),
            .subfields = &.{},
            .units = try sheets.list_split(message_cell(row, .units)),
        };

        return .{ .field = field, .numbered = number_text.len > 0 };
    }

    fn list_split(sheets: *Sheets, text: []const u8) CapacityError![]const []const u8 {
        assert(text.len <= xlsx.cell_bytes_max);

        if (text.len == 0) return &.{};

        const start = sheets.lists.count;

        var parts = std.mem.splitScalar(u8, text, list_separator);

        for (0..text.len + 1) |_| {
            const part = parts.next() orelse break;

            if (sheets.lists.full()) return error.ListsExhausted;

            const trimmed = std.mem.trim(u8, part, list_whitespace_bytes);

            sheets.lists.push_slot_assume_capacity().* = trimmed;
        }

        const result = sheets.lists.slice()[start..];

        assert(result.len >= 1);

        return result;
    }
};

pub const cell_bytes_max: u32 = xlsx.cell_bytes_max;
pub const field_count_max: u32 = 4096;
pub const list_item_count_max: u32 = 32 * 1024;
pub const message_count_max: u32 = 512;
pub const message_number_type = "mesg_num";
pub const pending_count_max: u32 = 1024;
pub const subfield_count_max: u32 = 2048;
pub const type_count_max: u32 = 512;
pub const value_count_max: u32 = 8192;

const base_decimal: u8 = 10;
const base_hexadecimal: u8 = 16;
const hexadecimal_prefix = "0x";
const list_separator = ',';
const list_whitespace_bytes = " \t\n\r";

const base_types = [_]struct { []const u8, []const u8 }{
    .{ "enum", "enum_value" },
    .{ "sint8", "sint8" },
    .{ "uint8", "uint8" },
    .{ "sint16", "sint16" },
    .{ "uint16", "uint16" },
    .{ "sint32", "sint32" },
    .{ "uint32", "uint32" },
    .{ "string", "string" },
    .{ "float32", "float32" },
    .{ "float64", "float64" },
    .{ "uint8z", "uint8z" },
    .{ "uint16z", "uint16z" },
    .{ "uint32z", "uint32z" },
    .{ "byte", "byte" },
    .{ "sint64", "sint64" },
    .{ "uint64", "uint64" },
    .{ "uint64z", "uint64z" },
    .{ "bool", "enum_value" },
};

comptime {
    assert(base_types.len == 18);
    assert(base_decimal < base_hexadecimal);
    assert(hexadecimal_prefix.len == 2);
}

pub fn int_parse(text: []const u8) ?i64 {
    assert(text.len <= xlsx.cell_bytes_max);

    if (text.len == 0) return null;

    const hexadecimal = std.ascii.startsWithIgnoreCase(text, hexadecimal_prefix);
    const digits = if (hexadecimal) text[hexadecimal_prefix.len..] else text;
    const base = if (hexadecimal) base_hexadecimal else base_decimal;

    if (digits.len == 0) return null;
    return std.fmt.parseInt(i64, digits, base) catch null;
}

fn field_number_parse(text: []const u8) Error!u8 {
    assert(text.len > 0);
    assert(text.len <= xlsx.cell_bytes_max);

    const number = int_parse(text) orelse return error.FieldNumberInvalid;
    if (number < 0) return error.FieldNumberInvalid;
    if (number > std.math.maxInt(u8)) return error.FieldNumberInvalid;

    const result: u8 = @intCast(number);

    assert(result == number);

    return result;
}

fn type_cell(row: Row, column: TypeColumn) []const u8 {
    assert(row.len <= xlsx.row_cells_max);

    const index = @backingInt(column);

    if (index >= row.len) return "";
    return row[index];
}

fn message_cell(row: Row, column: MessageColumn) []const u8 {
    assert(row.len <= xlsx.row_cells_max);

    const index = @backingInt(column);

    if (index >= row.len) return "";
    return row[index];
}

fn base_type_find(fit_type: []const u8) ?[]const u8 {
    assert(fit_type.len <= xlsx.cell_bytes_max);

    if (fit_type.len == 0) return null;

    for (base_types) |pair| {
        if (std.mem.eql(u8, pair[0], fit_type)) return pair[1];
    }

    return null;
}

pub const type_rows_fixture = [_]Row{
    &.{ "Type Name", "Base Type", "Value Name", "Value", "Comment" },
    &.{ "file", "enum" },
    &.{ "", "", "device", "1" },
    &.{ "", "", "settings", "2" },
    &.{ "", "", "settings_again", "2" },
    &.{ "", "", "negative", "-1" },
    &.{ "manufacturer", "uint16" },
    &.{ "", "", "garmin", "1" },
    &.{ "mesg_num", "uint16" },
    &.{ "", "", "record", "20" },
    &.{ "", "", "file_id", "0x00" },
    &.{ "undocumented", "uint8" },
};

pub const message_rows_fixture = [_]Row{
    &.{ "Message Name", "Field Def #", "Field Name", "Field Type" },
    &.{ "orphaned", "", "stray", "uint8" },
    &.{"record"},
    &.{ "", "1", "manufacturer", "manufacturer" },
    &.{ "", "6", "speed", "uint16", "", "enhanced_speed", "1000", "", "m/s", "16" },
    &.{ "", "73", "enhanced_speed", "uint32", "", "", "1000", "", "m/s" },
    &.{ "", "2", "product", "uint16" },
    &.{
        "",
        "",
        "garmin_product",
        "manufacturer",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "manufacturer",
        "garmin",
    },
    &.{ "", "10", "counter", "uint8", "1", "", "", "", "", "", "true" },
    &.{"undocumented_message"},
    &.{ "", "0", "whatever", "uint8" },
};

pub const Fixture = struct {
    messages: []const Row,
    types: []const Row,
};

pub const fixture: Fixture = .{ .messages = &message_rows_fixture, .types = &type_rows_fixture };

pub fn fixture_parse(sheets: *Sheets, rows: *const Fixture) Error!void {
    assert(rows.types.len > 0);
    assert(rows.messages.len > 0);

    sheets.init();

    for (rows.types[1..]) |row| try sheets.type_row_take(row);
    for (rows.messages[1..]) |row| try sheets.message_row_take(row);

    try sheets.messages_finish();
}

test "types keep sheet order, drop repeats, and drop negative values" {
    const sheets = try std.testing.allocator.create(Sheets);
    defer std.testing.allocator.destroy(sheets);

    try fixture_parse(sheets, &fixture);

    try std.testing.expectEqual(@as(u32, 4), sheets.types.count);
    try std.testing.expectEqualStrings("file", sheets.types.slice()[0].name);

    const file = sheets.type_named("file").?;

    try std.testing.expectEqualStrings("enum", file.base);
    try std.testing.expectEqual(@as(usize, 2), file.values.len);
    try std.testing.expectEqualStrings("device", file.values[0].name);
    try std.testing.expectEqualStrings("settings", file.values[1].name);
    try std.testing.expectEqual(@as(?i64, 2), file.value_of("settings"));
    try std.testing.expect(file.value_of("settings_again") == null);
    try std.testing.expect(file.value_of("negative") == null);
}

test "a repeated type name is rejected rather than emitted twice" {
    const sheets = try std.testing.allocator.create(Sheets);
    defer std.testing.allocator.destroy(sheets);

    const duplicated = [_]Row{
        &.{ "Type Name", "Base Type" },
        &.{ "file", "enum" },
        &.{ "file", "enum" },
    };

    const parsed = fixture_parse(sheets, &.{
        .messages = &message_rows_fixture,
        .types = &duplicated,
    });

    try std.testing.expectError(error.TypeDuplicate, parsed);
}

test "a type with no named values carries no type id but still resolves a base" {
    const sheets = try std.testing.allocator.create(Sheets);
    defer std.testing.allocator.destroy(sheets);

    try fixture_parse(sheets, &fixture);

    try std.testing.expectEqualStrings("file", sheets.type_id_of("file").?);
    try std.testing.expect(sheets.type_id_of("undocumented") == null);
    try std.testing.expectEqualStrings("uint8", sheets.base_type_of("undocumented").?);
    try std.testing.expectEqualStrings("uint16", sheets.base_type_of("uint16").?);
    try std.testing.expectEqualStrings("enum_value", sheets.base_type_of("bool").?);
    try std.testing.expectEqualStrings("uint16", sheets.base_type_of("manufacturer").?);
    try std.testing.expect(sheets.base_type_of("not_a_type") == null);
}

test "global numbers come from mesg_num and accept a hexadecimal value" {
    const sheets = try std.testing.allocator.create(Sheets);
    defer std.testing.allocator.destroy(sheets);

    try fixture_parse(sheets, &fixture);

    try std.testing.expectEqual(@as(?i64, 20), sheets.global_number("record"));
    try std.testing.expectEqual(@as(?i64, 0), sheets.global_number("file_id"));
    try std.testing.expect(sheets.global_number("undocumented_message") == null);
}

test "messages keep their fields and drop a subfield row that has no field" {
    const sheets = try std.testing.allocator.create(Sheets);
    defer std.testing.allocator.destroy(sheets);

    try fixture_parse(sheets, &fixture);

    const messages = sheets.messages.slice();

    try std.testing.expectEqual(@as(usize, 3), messages.len);
    try std.testing.expectEqualStrings("orphaned", messages[0].name);
    try std.testing.expectEqual(@as(usize, 0), messages[0].fields.len);

    const record = &messages[1];

    try std.testing.expectEqualStrings("record", record.name);
    try std.testing.expectEqual(@as(usize, 5), record.fields.len);
    try std.testing.expectEqual(@as(?u8, 6), record.field_named("speed").?.number);
    try std.testing.expect(record.field_named("missing") == null);
}

test "a field's subfield rows attach to the field above them" {
    const sheets = try std.testing.allocator.create(Sheets);
    defer std.testing.allocator.destroy(sheets);

    try fixture_parse(sheets, &fixture);

    const record = &sheets.messages.slice()[1];
    const product = record.field_named("product").?;

    try std.testing.expectEqual(@as(usize, 1), product.subfields.len);
    try std.testing.expectEqualStrings("garmin_product", product.subfields[0].name);
    try std.testing.expectEqual(@as(usize, 0), record.field_named("speed").?.subfields.len);
}

test "a list column splits on commas and trims each entry" {
    const sheets = try std.testing.allocator.create(Sheets);
    defer std.testing.allocator.destroy(sheets);

    const listed = [_]Row{
        &.{ "Message Name", "Field Def #", "Field Name", "Field Type" },
        &.{"record"},
        &.{ "", "0", "packed", "uint32", "", " a , b ,c", "1, 2", "", "m,s", "8,16" },
    };

    try fixture_parse(sheets, &.{ .messages = &listed, .types = &type_rows_fixture });

    const field = sheets.messages.slice()[0].field_named("packed").?;

    try std.testing.expectEqual(@as(usize, 3), field.components.len);
    try std.testing.expectEqualStrings("a", field.components[0]);
    try std.testing.expectEqualStrings("b", field.components[1]);
    try std.testing.expectEqualStrings("c", field.components[2]);
    try std.testing.expectEqual(@as(usize, 2), field.bits.len);
    try std.testing.expectEqualStrings("16", field.bits[1]);
}

test int_parse {
    try std.testing.expectEqual(@as(?i64, 20), int_parse("20"));
    try std.testing.expectEqual(@as(?i64, -3), int_parse("-3"));
    try std.testing.expectEqual(@as(?i64, 255), int_parse("0xFF"));
    try std.testing.expectEqual(@as(?i64, 255), int_parse("0Xff"));
    try std.testing.expect(int_parse("") == null);
    try std.testing.expect(int_parse("0x") == null);
    try std.testing.expect(int_parse("1.5") == null);
    try std.testing.expect(int_parse("garmin") == null);
}

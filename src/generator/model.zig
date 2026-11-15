const std = @import("std");

const bounded = @import("bounded");

const render = @import("render.zig");
const sheets_module = @import("sheets.zig");

const assert = std.debug.assert;

const FieldRow = sheets_module.FieldRow;
const MessageDefinition = sheets_module.MessageDefinition;
const NamedValue = sheets_module.NamedValue;
const Sheets = sheets_module.Sheets;

pub const CapacityError = error{
    ComponentsExhausted,
    FieldsExhausted,
    MessagesExhausted,
    SubfieldsExhausted,
    TypesExhausted,
};

pub const Error = CapacityError || error{
    ComponentBitsInvalid,
    GlobalNumberInvalid,
    OffsetInvalid,
    ReferenceValueInvalid,
    ScaleInvalid,
};

pub const Component = struct {
    field_number: u8,
    bits: u8,
    scale: f64,
    offset: f64,
    accumulate: bool,
};

pub const Subfield = struct {
    name: []const u8,
    type_name: []const u8,
    type_index: ?u16,
    scale: f64,
    offset: f64,
    units: []const u8,
    reference_field_number: u8,
    reference_value: i64,
};

pub const Field = struct {
    number: u8,
    name: []const u8,
    type_name: []const u8,
    type_index: ?u16,
    base_type: ?render.EnumLiteral,
    scale: f64,
    offset: f64,
    units: []const u8,
    array: bool,
    accumulate: bool,
    components: []const Component,
    subfields: []const Subfield,
};

pub const Message = struct {
    fields: []const Field,
    global_number: u16,
    name: []const u8,
};

pub const TypeTable = struct {
    name: []const u8,
    values: []const NamedValue,
};

const Scaling = struct {
    offset: f64,
    scale: f64,
};

const ScalingTexts = struct {
    offset: []const u8,
    scale: []const u8,
};

pub const Model = struct {
    components: bounded.ArrayType(Component, sheets_module.list_item_count_max),
    fields: bounded.ArrayType(Field, sheets_module.field_count_max),
    messages: bounded.ArrayType(Message, sheets_module.message_count_max),
    subfields: bounded.ArrayType(Subfield, sheets_module.subfield_count_max),
    types: bounded.ArrayType(TypeTable, sheets_module.type_count_max),

    pub fn resolve(model: *Model, source: *const Sheets) Error!void {
        assert(source.types.count > 0);
        assert(source.messages.count > 0);

        model.components = .empty;
        model.fields = .empty;
        model.messages = .empty;
        model.subfields = .empty;
        model.types = .empty;

        for (source.types.slice()) |definition| {
            if (definition.values.len == 0) continue;
            if (model.types.full()) return error.TypesExhausted;

            model.types.push_slot_assume_capacity().* = .{
                .name = definition.name,
                .values = definition.values,
            };
        }

        for (source.messages.slice()) |*definition| {
            const number = source.global_number(definition.name) orelse continue;
            if (number > std.math.maxInt(u16)) return error.GlobalNumberInvalid;
            if (model.messages.full()) return error.MessagesExhausted;

            const fields = try model.fields_resolve(source, definition);

            model.messages.push_slot_assume_capacity().* = .{
                .fields = fields,
                .global_number = @intCast(number),
                .name = definition.name,
            };
        }

        assert(model.types.count > 0);
        assert(model.messages.count > 0);
    }

    fn fields_resolve(
        model: *Model,
        source: *const Sheets,
        message: *const MessageDefinition,
    ) Error![]const Field {
        assert(message.name.len > 0);
        assert(source.types.count > 0);

        const start = model.fields.count;

        for (message.fields) |*row| {
            const number = row.number orelse continue;

            const scaling = try scaling_parse(.{
                .offset = first(row.offset),
                .scale = first(row.scale),
            });

            const components = try model.components_resolve(message, row);
            const subfields = try model.subfields_resolve(source, message, row);

            if (model.fields.full()) return error.FieldsExhausted;

            model.fields.push_slot_assume_capacity().* = .{
                .number = number,
                .name = row.name,
                .type_name = row.fit_type,
                .type_index = model.type_index_of(source, row.fit_type),
                .base_type = enum_literal(source.base_type_of(row.fit_type)),
                .scale = scaling.scale,
                .offset = scaling.offset,
                .units = first(row.units),
                .array = row.array.len > 0,
                .accumulate = true_is(first(row.accumulate)),
                .components = components,
                .subfields = subfields,
            };
        }

        const result = model.fields.slice()[start..];

        assert(result.len <= message.fields.len);

        return result;
    }

    fn components_resolve(
        model: *Model,
        message: *const MessageDefinition,
        row: *const FieldRow,
    ) Error![]const Component {
        assert(row.name.len > 0);
        assert(message.name.len > 0);

        const start = model.components.count;

        for (row.components, 0..) |name, position| {
            const index: u32 = @intCast(position);
            const target = message.field_named(name) orelse continue;
            const number = target.number orelse continue;
            const bits = sheets_module.int_parse(at(row.bits, index, "0")) orelse 0;

            if (bits < 0) return error.ComponentBitsInvalid;
            if (bits > component_bits_max) return error.ComponentBitsInvalid;
            if (model.components.full()) return error.ComponentsExhausted;

            const scaling = try scaling_parse(.{
                .offset = at(row.offset, index, ""),
                .scale = at(row.scale, index, ""),
            });

            model.components.push_slot_assume_capacity().* = .{
                .field_number = number,
                .bits = @intCast(bits),
                .scale = scaling.scale,
                .offset = scaling.offset,
                .accumulate = true_is(at(row.accumulate, index, "")),
            };
        }

        const result = model.components.slice()[start..];

        assert(result.len <= row.components.len);

        return result;
    }

    fn subfields_resolve(
        model: *Model,
        source: *const Sheets,
        message: *const MessageDefinition,
        row: *const FieldRow,
    ) Error![]const Subfield {
        assert(row.name.len > 0);
        assert(message.name.len > 0);

        const start = model.subfields.count;

        for (row.subfields) |*subfield| {
            const scaling = try scaling_parse(.{
                .offset = first(subfield.offset),
                .scale = first(subfield.scale),
            });

            const pairs = @min(subfield.reference_fields.len, subfield.reference_values.len);

            for (0..pairs) |index| {
                const name = subfield.reference_fields[index];
                const reference = message.field_named(name) orelse continue;
                const number = reference.number orelse continue;

                const value = source.value_of(reference, subfield.reference_values[index]) orelse
                    continue;

                if (value < 0) return error.ReferenceValueInvalid;
                if (model.subfields.full()) return error.SubfieldsExhausted;

                model.subfields.push_slot_assume_capacity().* = .{
                    .name = subfield.name,
                    .type_name = subfield.fit_type,
                    .type_index = model.type_index_of(source, subfield.fit_type),
                    .scale = scaling.scale,
                    .offset = scaling.offset,
                    .units = first(subfield.units),
                    .reference_field_number = number,
                    .reference_value = value,
                };
            }
        }

        return model.subfields.slice()[start..];
    }

    fn type_index_of(model: *const Model, source: *const Sheets, fit_type: []const u8) ?u16 {
        assert(fit_type.len <= sheets_module.cell_bytes_max);
        assert(model.types.count <= std.math.maxInt(u16));

        const name = source.type_id_of(fit_type) orelse return null;

        for (model.types.slice(), 0..) |table, index| {
            if (std.mem.eql(u8, table.name, name)) {
                const result: u16 = @intCast(index);

                assert(result < model.types.count);

                return result;
            }
        }

        unreachable;
    }
};

const boolean_one = "1";
const boolean_true = "true";
const component_bits_max: u32 = 64;
const offset_identity: f64 = 0.0;
const scale_identity: f64 = 1.0;

comptime {
    assert(component_bits_max <= std.math.maxInt(u8));
    assert(boolean_true.len == 4);
}

fn scaling_parse(texts: ScalingTexts) Error!Scaling {
    assert(texts.scale.len <= std.math.maxInt(u32));
    assert(texts.offset.len <= std.math.maxInt(u32));

    const scale = try scale_parse(texts.scale);
    const result: Scaling = .{ .offset = try offset_parse(texts.offset), .scale = scale };

    assert(result.scale != 0.0);
    assert(std.math.isFinite(result.offset));

    return result;
}

fn scale_parse(text: []const u8) Error!f64 {
    assert(text.len <= std.math.maxInt(u32));

    if (text.len == 0) return scale_identity;

    const scale = std.fmt.parseFloat(f64, text) catch return error.ScaleInvalid;
    if (!std.math.isFinite(scale)) return error.ScaleInvalid;
    if (scale == 0.0) return scale_identity;

    assert(scale != 0.0);

    return scale;
}

fn offset_parse(text: []const u8) Error!f64 {
    assert(text.len <= std.math.maxInt(u32));

    if (text.len == 0) return offset_identity;

    const offset = std.fmt.parseFloat(f64, text) catch return error.OffsetInvalid;
    if (!std.math.isFinite(offset)) return error.OffsetInvalid;

    assert(!std.math.isNan(offset));

    return offset;
}

fn enum_literal(name: ?[]const u8) ?render.EnumLiteral {
    if (name == null) return null;

    const present = name.?;

    assert(present.len > 0);
    assert(std.mem.findScalar(u8, present, ' ') == null);

    return .{ .name = present };
}

fn first(list: []const []const u8) []const u8 {
    assert(list.len <= sheets_module.list_item_count_max);

    if (list.len == 0) return "";
    return list[0];
}

fn at(list: []const []const u8, index: u32, fallback: []const u8) []const u8 {
    assert(list.len <= sheets_module.list_item_count_max);
    assert(index < sheets_module.list_item_count_max);
    assert(fallback.len <= 1);

    if (index >= list.len) return fallback;
    return list[index];
}

fn true_is(text: []const u8) bool {
    assert(text.len <= std.math.maxInt(u32));

    if (std.mem.eql(u8, text, boolean_one)) return true;
    return std.ascii.eqlIgnoreCase(text, boolean_true);
}

const TestState = struct {
    model: Model,
    sheets: Sheets,
};

fn fixture_resolve(state: *TestState) !void {
    try sheets_module.fixture_parse(&state.sheets, &sheets_module.fixture);

    try state.model.resolve(&state.sheets);
}

test "only types with named values and messages with a global number survive" {
    const state = try std.testing.allocator.create(TestState);
    defer std.testing.allocator.destroy(state);

    try fixture_resolve(state);

    try std.testing.expectEqual(@as(u32, 3), state.model.types.count);
    try std.testing.expectEqual(@as(u32, 1), state.model.messages.count);
    try std.testing.expectEqualStrings("record", state.model.messages.slice()[0].name);
    try std.testing.expectEqual(@as(u16, 20), state.model.messages.slice()[0].global_number);
}

test "a field resolves its type index, base type, units, and scaling" {
    const state = try std.testing.allocator.create(TestState);
    defer std.testing.allocator.destroy(state);

    try fixture_resolve(state);

    const fields = state.model.messages.slice()[0].fields;
    const speed = fields[1];

    try std.testing.expectEqualStrings("speed", speed.name);
    try std.testing.expectEqual(@as(u8, 6), speed.number);
    try std.testing.expect(speed.type_index == null);
    try std.testing.expectEqualStrings("uint16", speed.base_type.?.name);
    try std.testing.expectEqualStrings("m/s", speed.units);
    try std.testing.expectApproxEqAbs(@as(f64, 1000.0), speed.scale, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), speed.offset, 1e-9);

    const manufacturer = fields[0];

    try std.testing.expectEqual(@as(?u16, 1), manufacturer.type_index);
    try std.testing.expectEqualStrings("manufacturer", manufacturer.type_name);
    try std.testing.expectEqualStrings("uint16", manufacturer.base_type.?.name);
}

test "an accumulate column of 1 reads as true, as the FIT SDK workbook writes it" {
    try std.testing.expect(true_is("1"));
    try std.testing.expect(true_is("true"));
    try std.testing.expect(true_is("TRUE"));
    try std.testing.expect(!true_is("0"));
    try std.testing.expect(!true_is(""));
    try std.testing.expect(!true_is("10"));
}

test "the array and accumulate columns resolve to flags" {
    const state = try std.testing.allocator.create(TestState);
    defer std.testing.allocator.destroy(state);

    try fixture_resolve(state);

    const fields = state.model.messages.slice()[0].fields;
    const counter = fields[4];

    try std.testing.expectEqualStrings("counter", counter.name);
    try std.testing.expect(counter.array);
    try std.testing.expect(counter.accumulate);
    try std.testing.expect(!fields[1].array);
    try std.testing.expect(!fields[1].accumulate);
}

test "components resolve their target field, bits, and scaling" {
    const state = try std.testing.allocator.create(TestState);
    defer std.testing.allocator.destroy(state);

    try fixture_resolve(state);

    const speed = state.model.messages.slice()[0].fields[1];

    try std.testing.expectEqual(@as(usize, 1), speed.components.len);
    try std.testing.expectEqual(@as(u8, 73), speed.components[0].field_number);
    try std.testing.expectEqual(@as(u8, 16), speed.components[0].bits);
    try std.testing.expectApproxEqAbs(@as(f64, 1000.0), speed.components[0].scale, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), speed.components[0].offset, 1e-9);
    try std.testing.expect(!speed.components[0].accumulate);
}

test "subfields resolve their reference field number and enum value" {
    const state = try std.testing.allocator.create(TestState);
    defer std.testing.allocator.destroy(state);

    try fixture_resolve(state);

    const product = state.model.messages.slice()[0].fields[3];

    try std.testing.expectEqualStrings("product", product.name);
    try std.testing.expectEqual(@as(usize, 1), product.subfields.len);

    const subfield = product.subfields[0];

    try std.testing.expectEqualStrings("garmin_product", subfield.name);
    try std.testing.expectEqual(@as(?u16, 1), subfield.type_index);
    try std.testing.expectEqual(@as(u8, 1), subfield.reference_field_number);
    try std.testing.expectEqual(@as(i64, 1), subfield.reference_value);
}

test "a blank or zero scale reads as unscaled" {
    const state = try std.testing.allocator.create(TestState);
    defer std.testing.allocator.destroy(state);

    try fixture_resolve(state);

    const product = state.model.messages.slice()[0].fields[3];

    try std.testing.expectApproxEqAbs(@as(f64, 1.0), product.scale, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), product.offset, 1e-9);
}

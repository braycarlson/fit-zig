const std = @import("std");

const base_type_module = @import("base_type.zig");
const types_module = @import("profile/types.zig");

const assert = std.debug.assert;

const BaseType = base_type_module.BaseType;

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
    base_type: ?BaseType,
    scale: f64,
    offset: f64,
    units: []const u8,
    array: bool,
    accumulate: bool,
    components: []const Component,
    subfields: []const Subfield,
};

pub const Message = struct {
    global_number: u16,
    name: []const u8,
    fields: []const Field,

    pub fn field_of(message: *const Message, number: u8) ?*const Field {
        assert(message.name.len > 0);
        assert(message.fields.len <= std.math.maxInt(u8) + 1);

        for (message.fields) |*field| {
            if (field.number == number) return field;
        }

        return null;
    }
};

pub const TypeValue = struct {
    type_index: u16,
    value: u64,
    name: []const u8,
};

pub const TypeValueKey = struct {
    type_index: u16,
    value: u64,
};

pub const accumulator_count_max: u32 = accumulator_count();
pub const component_count_max: u32 = component_count();
pub const messages = &@import("profile/messages.zig").messages;
pub const type_count: u32 = types_module.type_names.len;

comptime {
    @setEvalBranchQuota(4_000_000);

    assert(type_count > 0);
    assert(type_count <= std.math.maxInt(u16));
    assert(types_module.type_values.len > 0);
    assert(messages.len > 0);

    for (types_module.type_values[1..], 0..) |item, index| {
        const previous = types_module.type_values[index];
        const key: TypeValueKey = .{ .type_index = previous.type_index, .value = previous.value };

        assert(item.name.len > 0);
        assert(item.type_index < type_count);
        assert(type_value_order(&key, item) == .lt);
    }

    for (messages, 0..) |*message, index| {
        assert(message.name.len > 0);

        for (messages[index + 1 ..]) |later| {
            assert(later.global_number != message.global_number);
        }

        for (message.fields) |field| {
            assert(field.name.len > 0);
            assert(field.scale != 0.0);
            assert(std.math.isFinite(field.scale));
            assert(std.math.isFinite(field.offset));

            if (field.type_index) |type_index| assert(type_index < type_count);

            for (field.subfields) |subfield| {
                assert(subfield.name.len > 0);
                assert(subfield.scale != 0.0);
                assert(subfield.reference_value >= 0);
            }

            for (field.components) |component| {
                assert(component.scale != 0.0);
                assert(std.math.isFinite(component.offset));
            }
        }
    }
}

pub fn message_of(global_number: u16) ?*const Message {
    assert(messages.len > 0);
    assert(messages.len <= std.math.maxInt(u16));

    for (messages) |*message| {
        if (message.global_number == global_number) return message;
    }

    return null;
}

pub fn type_value_name(key: *const TypeValueKey) ?[]const u8 {
    assert(key.type_index < type_count);
    assert(types_module.type_values.len > 0);

    const values = &types_module.type_values;
    const found = std.sort.binarySearch(TypeValue, values, key, type_value_order);
    const index = found orelse return null;

    assert(values[index].type_index == key.type_index);
    assert(values[index].value == key.value);

    return values[index].name;
}

pub fn type_find(name: []const u8) ?u16 {
    assert(name.len > 0);
    assert(type_count > 0);

    for (types_module.type_names, 0..) |type_name, index| {
        if (std.mem.eql(u8, type_name, name)) {
            const result: u16 = @intCast(index);

            assert(result < type_count);

            return result;
        }
    }

    return null;
}

fn accumulator_count() u32 {
    @setEvalBranchQuota(1_000_000);

    var result: u32 = 0;

    for (messages) |message| {
        for (message.fields) |field| {
            if (field.accumulate) result += 1;

            for (field.components) |component| {
                if (component.accumulate) result += 1;
            }
        }
    }

    assert(result > 0);

    return result;
}

fn component_count() u32 {
    @setEvalBranchQuota(1_000_000);

    var result: u32 = 0;

    for (messages) |message| {
        for (message.fields) |field| result = @max(result, field.components.len);
    }

    assert(result > 0);

    return result;
}

fn type_value_order(key: *const TypeValueKey, item: TypeValue) std.math.Order {
    assert(item.name.len > 0);
    assert(key.type_index < type_count);

    if (key.type_index != item.type_index) return std.math.order(key.type_index, item.type_index);
    return std.math.order(key.value, item.value);
}

test message_of {
    const record = message_of(20) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqualStrings("record", record.name);

    const heart_rate = record.field_of(3) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqualStrings("heart_rate", heart_rate.name);
    try std.testing.expectEqualStrings("bpm", heart_rate.units);

    const speed = record.field_of(6) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqualStrings("m/s", speed.units);
    try std.testing.expectEqual(@as(f64, 1000.0), speed.scale);

    const file_id = message_of(0) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqualStrings("file_id", file_id.name);
    try std.testing.expect(message_of(64000) == null);
}

test type_value_name {
    const file = type_find("file") orelse return error.TestUnexpectedResult;
    const manufacturer = type_find("manufacturer") orelse return error.TestUnexpectedResult;
    const activity = type_value_name(&.{ .type_index = file, .value = 4 }).?;
    const garmin = type_value_name(&.{ .type_index = manufacturer, .value = 1 }).?;
    const absent = type_value_name(&.{ .type_index = file, .value = 0xFFFF });

    try std.testing.expectEqualStrings("activity", activity);
    try std.testing.expectEqualStrings("garmin", garmin);
    try std.testing.expect(absent == null);
    try std.testing.expect(type_find("not_a_type") == null);
}

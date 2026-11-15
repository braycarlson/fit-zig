const std = @import("std");

const base_type_module = @import("base_type.zig");
const garmin = @import("garmin.zig");
const parser_module = @import("parser.zig");
const profile = @import("profile.zig");
const value_module = @import("value.zig");

const Endian = std.lang.Endian;
const assert = std.debug.assert;

const BaseType = base_type_module.BaseType;
const DataMessage = Parser.DataMessage;
const Diagnostic = parser_module.Diagnostic;
const Meta = value_module.Meta;
const Parser = parser_module.Parser;
const RawField = Parser.Field;

pub const Capacity = struct {
    accumulator_count_max: u32,
    developer_field_count_max: u32,
    field_count_max: u32,
    text_bytes_max: u32,
};

pub const Storage = struct {
    accumulators: []Decoder.Accumulator,
    descriptions: []Decoder.FieldDescription,
    fields: []Decoder.Field,
    names: [][name_bytes_max]u8,
    text: []u8,
};

pub const Decoder = struct {
    accumulator_count: u32,
    description_count: u32,
    diagnostic: Diagnostic,
    field_count: u32,
    parser: Parser,
    resolutions: [parser_module.local_type_count]Resolution,
    storage: Storage,
    text_count: u32,

    pub const Accumulator = struct {
        key: u32,
        total: u64,
    };

    pub const CapacityError = Parser.CapacityError || error{
        AccumulatorsExhausted,
        DescriptionsExhausted,
        FieldsExhausted,
        TextExhausted,
    };

    pub const Error = CapacityError || SyntaxError;
    pub const SyntaxError = Parser.SyntaxError;

    pub const Field = struct {
        name: []const u8,
        number: u8,
        type_name: []const u8,
        units: []const u8,
        value: Value,
    };

    pub const FieldDescription = struct {
        base_type: BaseType,
        key: u16,
        name: []const u8,
        offset: f64,
        scale: f64,
        units: []const u8,
    };

    pub const Message = struct {
        fields: []const Field,
        global_number: u16,
        name: []const u8,
        timestamp: ?u32,
    };

    pub const Next = union(enum) {
        end,
        message: Message,
    };

    pub const Value = value_module.Value;

    const Resolution = struct {
        fields: [parser_module.field_count_max]?*const profile.Field,
        message: ?*const profile.Message,
        sequence: u32,
    };

    const Resolved = struct {
        field: ?*const profile.Field,
        message: ?*const profile.Message,
    };

    const Target = struct {
        field: *const profile.Field,
        message: *const profile.Message,
    };

    pub fn init(decoder: *Decoder, storage: Storage, bytes: []const u8) SyntaxError!void {
        assert(storage.fields.len == storage.names.len);
        assert(bytes.len <= parser_module.source_bytes_max);

        decoder.accumulator_count = 0;
        decoder.description_count = 0;
        decoder.diagnostic = .{ .offset = 0 };
        decoder.field_count = 0;
        decoder.storage = storage;
        decoder.text_count = 0;

        for (&decoder.resolutions) |*resolution| resolution.sequence = 0;

        decoder.parser.init(bytes) catch |err| {
            decoder.diagnostic = decoder.parser.diagnostic;

            return err;
        };
    }

    pub fn next(decoder: *Decoder) Error!Next {
        assert(decoder.accumulator_count <= decoder.storage.accumulators.len);
        assert(decoder.text_count <= decoder.storage.text.len);

        const found = decoder.parser.next() catch |err| {
            decoder.diagnostic = decoder.parser.diagnostic;

            return err;
        };

        const message = switch (found) {
            .end => return .end,
            .message => |message| message,
        };

        const result = decoder.message_decode(&message) catch |err| {
            decoder.diagnostic = .{ .offset = message.offset };

            return err;
        };

        assert(result.fields.len == decoder.field_count);
        assert(result.name.len > 0);

        return .{ .message = result };
    }

    pub fn header(decoder: *const Decoder) Parser.Header {
        assert(decoder.parser.data_end <= decoder.parser.bytes.len);

        const result = decoder.parser.header;

        assert(result.size_bytes >= parser_module.header_bytes_min);

        return result;
    }

    pub fn timestamp_last(decoder: *const Decoder) ?u32 {
        assert(decoder.parser.cursor <= decoder.parser.data_end);

        const result = decoder.parser.timestamp;

        if (result) |timestamp| assert(timestamp != timestamp_invalid);

        return result;
    }

    fn message_decode(decoder: *Decoder, message: *const DataMessage) CapacityError!Message {
        assert(message.payload.len == message.definition.payload_size_bytes);

        const resolution = decoder.resolve(message);

        decoder.field_count = 0;

        var raw_fields = message.fields();

        for (0..parser_module.field_count_max) |index| {
            const raw = raw_fields.next() orelse break;

            try decoder.field_push(message, &raw, &.{
                .field = resolution.fields[index],
                .message = resolution.message,
            });
        }

        try decoder.developer_fields_push(message);

        if (message.global_number == field_description_number) {
            try decoder.field_description_learn(message);
        }

        if (message.global_number == garmin.channel_message_number) {
            try decoder.channel_samples_push(message);
        }

        const name = if (resolution.message) |found|
            found.name
        else
            garmin.message_name(message.global_number) orelse unknown_message_name;

        assert(decoder.field_count >= message.definition.field_count);

        return .{
            .fields = decoder.storage.fields[0..decoder.field_count],
            .global_number = message.global_number,
            .name = name,
            .timestamp = message.timestamp,
        };
    }

    fn resolve(decoder: *Decoder, message: *const DataMessage) *const Resolution {
        assert(message.definition.sequence > 0);

        const definition = message.definition;
        const resolution = &decoder.resolutions[message.local_type];

        if (resolution.sequence == definition.sequence) return resolution;

        resolution.message = profile.message_of(definition.global_number);
        resolution.sequence = definition.sequence;

        for (0..definition.field_count) |index| {
            const number = definition.fields[index].number;

            resolution.fields[index] = if (resolution.message) |profile_message|
                profile_message.field_of(number)
            else
                null;
        }

        assert(resolution.sequence == definition.sequence);

        return resolution;
    }

    fn field_push(
        decoder: *Decoder,
        message: *const DataMessage,
        raw: *const RawField,
        resolved: *const Resolved,
    ) CapacityError!void {
        assert(raw.bytes.len <= parser_module.field_bytes_max);
        assert(raw.architecture == message.architecture);

        const meta = if (resolved.field) |field|
            value_module.meta_of(message, field)
        else
            supplement_meta(message, raw);

        var value = field_value(raw, &meta);

        if (resolved.field) |field| {
            if (accumulates(raw, field)) value = try decoder.field_accumulate(message, raw, &meta);
        }

        const name = if (meta.name.len > 0)
            meta.name
        else
            try decoder.name_print(unknown_field_format, .{raw.number});

        try decoder.field_store(.{
            .name = name,
            .number = raw.number,
            .type_name = meta.type_name,
            .units = meta.units,
            .value = value,
        });

        const field = resolved.field orelse return;
        const profile_message = resolved.message orelse return;

        try decoder.components_expand(message, raw, &.{
            .field = field,
            .message = profile_message,
        });
    }

    fn field_accumulate(
        decoder: *Decoder,
        message: *const DataMessage,
        raw: *const RawField,
        meta: *const Meta,
    ) CapacityError!Value {
        assert(raw.bytes.len >= 1);
        assert(raw.bytes.len < value_module.bytes_max);

        const reading = value_module.field_unsigned(raw) orelse unreachable;
        const bits: u7 = @intCast(raw.bytes.len * 8);

        const key = accumulator_key(&.{
            .field_number = raw.number,
            .global_number = message.global_number,
        });

        const total = try decoder.accumulate(key, reading, bits);

        assert(total >= reading);

        return scaled_unsigned(&.{ .offset = meta.offset, .raw = total, .scale = meta.scale });
    }

    fn components_expand(
        decoder: *Decoder,
        message: *const DataMessage,
        raw: *const RawField,
        target: *const Target,
    ) CapacityError!void {
        assert(raw.bytes.len <= parser_module.field_bytes_max);
        assert(target.field.name.len > 0);

        const field = target.field;
        const profile_message = target.message;

        if (field.components.len == 0) return;

        const packed_value = value_module.raw_bits(raw) orelse return;

        var bit_offset: u32 = 0;

        for (field.components) |*component| {
            if (component.bits == 0) break;
            if (bit_offset + component.bits > packed_bits_max) break;

            const width: u7 = @intCast(component.bits);
            const mask = value_module.low_bits_mask(width);

            var extracted = (packed_value >> @intCast(bit_offset)) & mask;

            bit_offset += component.bits;

            if (component.accumulate) {
                const key = accumulator_key(&.{
                    .field_number = component.field_number,
                    .global_number = message.global_number,
                });

                extracted = try decoder.accumulate(key, extracted, width);
            }

            try decoder.component_push(profile_message, component, extracted);
        }

        assert(bit_offset <= packed_bits_max);
    }

    fn component_push(
        decoder: *Decoder,
        profile_message: *const profile.Message,
        component: *const profile.Component,
        raw: u64,
    ) CapacityError!void {
        assert(component.bits >= 1);
        assert(component.bits <= packed_bits_max);

        const mask = value_module.low_bits_mask(@intCast(component.bits));

        if (!component.accumulate) assert(raw <= mask);

        const target = profile_message.field_of(component.field_number);

        const name = if (target) |field|
            field.name
        else
            try decoder.name_print(unknown_field_format, .{component.field_number});

        try decoder.field_store(.{
            .name = name,
            .number = component.field_number,
            .type_name = if (target) |field| field.type_name else "",
            .units = if (target) |field| field.units else "",
            .value = scaled_unsigned(&.{
                .offset = component.offset,
                .raw = raw,
                .scale = component.scale,
            }),
        });
    }

    fn developer_fields_push(decoder: *Decoder, message: *const DataMessage) CapacityError!void {
        assert(message.definition.developer_field_count <= parser_module.field_count_max);

        const before = decoder.field_count;

        var developer_fields = message.developer_fields();

        for (0..parser_module.developer_field_count_max) |_| {
            const developer = developer_fields.next() orelse break;

            const key = developer_key(&.{
                .developer_data_index = developer.developer_data_index,
                .number = developer.number,
            });

            const description = decoder.description_find(key) orelse {
                try decoder.developer_opaque_push(developer);

                continue;
            };

            const meta: Meta = .{
                .name = description.name,
                .offset = description.offset,
                .scale = description.scale,
                .type_index = null,
                .type_name = "",
                .units = description.units,
            };

            const raw: RawField = .{
                .architecture = developer.architecture,
                .base_type = description.base_type,
                .bytes = developer.bytes,
                .number = developer.number,
            };

            try decoder.field_store(.{
                .name = description.name,
                .number = developer.number,
                .type_name = "",
                .units = description.units,
                .value = field_value(&raw, &meta),
            });
        }

        assert(decoder.field_count - before <= message.definition.developer_field_count);
    }

    fn developer_opaque_push(
        decoder: *Decoder,
        developer: Parser.DeveloperField,
    ) CapacityError!void {
        assert(developer.bytes.len <= parser_module.field_bytes_max);

        const name = try decoder.name_print(developer_name_format, .{
            developer.developer_data_index,
            developer.number,
        });

        assert(std.mem.startsWith(u8, name, developer_name_prefix));

        try decoder.field_store(.{
            .name = name,
            .number = developer.number,
            .type_name = "",
            .units = "",
            .value = .{ .bytes = developer.bytes },
        });
    }

    fn field_description_learn(decoder: *Decoder, message: *const DataMessage) CapacityError!void {
        assert(message.global_number == field_description_number);

        var learned: FieldDescriptionFields = .empty;
        var fields = message.fields();

        for (0..parser_module.field_count_max) |_| {
            const field = fields.next() orelse break;

            learned.take(&field);
        }

        const identity: DeveloperIdentity = .{
            .developer_data_index = learned.developer_data_index orelse return,
            .number = learned.number orelse return,
        };

        const key = developer_key(&identity);

        const name = if (learned.name.len > 0)
            try decoder.text_store(learned.name)
        else
            try decoder.text_print(developer_name_format, .{
                identity.developer_data_index,
                identity.number,
            });

        try decoder.description_store(.{
            .base_type = learned.base_type,
            .key = key,
            .name = name,
            .offset = learned.offset,
            .scale = learned.scale,
            .units = try decoder.text_store(learned.units),
        });

        assert(decoder.description_find(key) != null);
    }

    fn channel_samples_push(decoder: *Decoder, message: *const DataMessage) CapacityError!void {
        assert(message.global_number == garmin.channel_message_number);

        const before = decoder.field_count;

        var raw_fields = message.fields();

        for (0..parser_module.field_count_max) |_| {
            const raw = raw_fields.next() orelse break;
            if (raw.number != garmin.channel_field_number) continue;

            const sample = garmin.channel_sample(raw.bytes) orelse continue;

            try decoder.field_store(.{
                .name = garmin.channel_field_name,
                .number = garmin.channel_field_number,
                .type_name = "",
                .units = "",
                .value = .{ .unsigned = sample.id },
            });

            try decoder.field_store(.{
                .name = garmin.channel_value_field_name,
                .number = garmin.channel_field_number,
                .type_name = "",
                .units = "",
                .value = .{ .unsigned = sample.value },
            });
        }

        assert((decoder.field_count - before) % 2 == 0);
    }

    fn accumulate(decoder: *Decoder, key: u32, value: u64, bits: u7) CapacityError!u64 {
        assert(key <= accumulator_key_max);
        assert(bits >= 1);
        assert(value <= value_module.low_bits_mask(bits));

        const mask = value_module.low_bits_mask(bits);
        const accumulators = decoder.storage.accumulators[0..decoder.accumulator_count];

        const accumulator = for (accumulators) |*found| {
            if (found.key == key) break found;
        } else try decoder.accumulator_claim(key);

        accumulator.total +%= (value -% accumulator.total) & mask;

        assert(accumulator.total & mask == value);
        assert(accumulator.total >= value);

        return accumulator.total;
    }

    fn accumulator_claim(decoder: *Decoder, key: u32) CapacityError!*Accumulator {
        assert(key <= accumulator_key_max);
        assert(decoder.accumulator_count <= decoder.storage.accumulators.len);

        if (decoder.accumulator_count == decoder.storage.accumulators.len) {
            return error.AccumulatorsExhausted;
        }

        const result = &decoder.storage.accumulators[decoder.accumulator_count];

        result.* = .{ .key = key, .total = 0 };
        decoder.accumulator_count += 1;

        assert(decoder.accumulator_count <= decoder.storage.accumulators.len);

        return result;
    }

    fn description_find(decoder: *const Decoder, key: u16) ?*const FieldDescription {
        assert(decoder.description_count <= decoder.storage.descriptions.len);

        for (decoder.storage.descriptions[0..decoder.description_count]) |*description| {
            if (description.key == key) return description;
        }

        return null;
    }

    fn description_store(decoder: *Decoder, description: FieldDescription) CapacityError!void {
        assert(description.name.len > 0);
        assert(description.scale != 0.0);

        const descriptions = decoder.storage.descriptions[0..decoder.description_count];

        for (descriptions) |*existing| {
            if (existing.key == description.key) {
                existing.* = description;

                return;
            }
        }

        if (decoder.description_count == decoder.storage.descriptions.len) {
            return error.DescriptionsExhausted;
        }

        decoder.storage.descriptions[decoder.description_count] = description;
        decoder.description_count += 1;

        assert(decoder.description_count <= decoder.storage.descriptions.len);
    }

    fn field_store(decoder: *Decoder, field: Field) CapacityError!void {
        assert(field.name.len > 0);
        assert(decoder.field_count <= decoder.storage.fields.len);

        if (decoder.field_count == decoder.storage.fields.len) return error.FieldsExhausted;

        decoder.storage.fields[decoder.field_count] = field;
        decoder.field_count += 1;

        assert(decoder.field_count <= decoder.storage.fields.len);
    }

    fn name_print(
        decoder: *Decoder,
        comptime format: []const u8,
        arguments: anytype,
    ) CapacityError![]const u8 {
        comptime assert(format.len > 0);
        comptime assert(@typeInfo(@TypeOf(arguments)) == .@"struct");
        assert(decoder.field_count <= decoder.storage.names.len);

        if (decoder.field_count == decoder.storage.names.len) return error.FieldsExhausted;

        const target = &decoder.storage.names[decoder.field_count];

        const result = std.mem.print(target, format, arguments) catch |err| switch (err) {
            error.NoSpaceLeft => unreachable,
        };

        assert(result.len > 0);

        return result;
    }

    fn text_print(
        decoder: *Decoder,
        comptime format: []const u8,
        arguments: anytype,
    ) CapacityError![]const u8 {
        comptime assert(format.len > 0);
        comptime assert(@typeInfo(@TypeOf(arguments)) == .@"struct");
        assert(decoder.text_count <= decoder.storage.text.len);

        var buffer: [name_bytes_max]u8 = undefined;

        const printed = std.mem.print(&buffer, format, arguments) catch |err| switch (err) {
            error.NoSpaceLeft => unreachable,
        };

        return decoder.text_store(printed);
    }

    fn text_store(decoder: *Decoder, text: []const u8) CapacityError![]const u8 {
        assert(text.len <= parser_module.field_bytes_max);
        assert(decoder.text_count <= decoder.storage.text.len);

        if (text.len > decoder.storage.text.len - decoder.text_count) return error.TextExhausted;

        const result = decoder.storage.text[decoder.text_count..][0..text.len];

        @memcpy(result, text);
        decoder.text_count += @intCast(text.len);

        assert(std.mem.eql(u8, result, text));

        return result;
    }
};

const DeveloperIdentity = struct {
    developer_data_index: u8,
    number: u8,
};

const FieldIdentity = struct {
    field_number: u8,
    global_number: u16,
};

const Reading = struct {
    offset: f64,
    raw: u64,
    scale: f64,
};

const FieldDescriptionFields = struct {
    base_type: BaseType,
    developer_data_index: ?u8,
    name: []const u8,
    number: ?u8,
    offset: f64,
    scale: f64,
    units: []const u8,

    const empty: FieldDescriptionFields = .{
        .base_type = .uint8,
        .developer_data_index = null,
        .name = "",
        .number = null,
        .offset = 0.0,
        .scale = 1.0,
        .units = "",
    };

    fn take(learned: *FieldDescriptionFields, field: *const RawField) void {
        assert(field.bytes.len <= parser_module.field_bytes_max);
        assert(learned.scale != 0.0);

        switch (field.number) {
            0 => learned.developer_data_index = scalar_u8(field),
            1 => learned.number = scalar_u8(field),
            2 => if (scalar_u8(field)) |id| {
                learned.base_type = std.enums.fromInt(BaseType, id) orelse .uint8;
            },
            3 => learned.name = value_module.c_string(field.bytes),
            6 => if (scalar_u8(field)) |scale| {
                if (scale != 0) learned.scale = @floatFromInt(scale);
            },
            7 => if (scalar_i8(field)) |offset| {
                learned.offset = @floatFromInt(offset);
            },
            8 => learned.units = value_module.c_string(field.bytes),
            else => {},
        }
    }
};

pub fn DecoderType(comptime capacity: Capacity) type {
    comptime assert(capacity.accumulator_count_max > 0);
    comptime assert(capacity.developer_field_count_max > 0);
    comptime assert(capacity.field_count_max > 0);
    comptime assert(capacity.text_bytes_max > 0);

    return struct {
        base: Decoder,
        storage: StorageType(capacity),

        const Fixed = @This();

        pub fn init(fixed: *Fixed, bytes: []const u8) Decoder.SyntaxError!void {
            assert(bytes.len <= parser_module.source_bytes_max);
            assert(fixed.storage.fields.len == capacity.field_count_max);

            return fixed.base.init(fixed.storage.slices(), bytes);
        }

        pub fn next(fixed: *Fixed) Decoder.Error!Decoder.Next {
            assert(fixed.storage.fields.len == capacity.field_count_max);
            assert(fixed.storage.text.len == capacity.text_bytes_max);

            return fixed.base.next();
        }

        pub fn diagnostic(fixed: *const Fixed) Diagnostic {
            assert(fixed.storage.fields.len == capacity.field_count_max);

            return fixed.base.diagnostic;
        }

        pub fn header(fixed: *const Fixed) Parser.Header {
            assert(fixed.storage.fields.len == capacity.field_count_max);

            return fixed.base.header();
        }

        pub fn timestamp_last(fixed: *const Fixed) ?u32 {
            assert(fixed.storage.fields.len == capacity.field_count_max);

            return fixed.base.timestamp_last();
        }
    };
}

pub fn StorageType(comptime capacity: Capacity) type {
    comptime assert(capacity.field_count_max > 0);
    comptime assert(capacity.text_bytes_max > 0);

    return struct {
        accumulators: [capacity.accumulator_count_max]Decoder.Accumulator,
        descriptions: [capacity.developer_field_count_max]Decoder.FieldDescription,
        fields: [capacity.field_count_max]Decoder.Field,
        names: [capacity.field_count_max][name_bytes_max]u8,
        text: [capacity.text_bytes_max]u8,

        const Fixed = @This();

        pub fn slices(fixed: *Fixed) Storage {
            assert(fixed.fields.len == fixed.names.len);
            assert(fixed.text.len == capacity.text_bytes_max);

            return .{
                .accumulators = &fixed.accumulators,
                .descriptions = &fixed.descriptions,
                .fields = &fixed.fields,
                .names = &fixed.names,
                .text = &fixed.text,
            };
        }
    };
}

pub const name_bytes_max: u32 = 12;

const accumulator_key_max: u32 = 0xFFFFFF;
const developer_name_format = developer_name_prefix ++ "{d}_{d}";
const developer_name_prefix = "dev_";
const field_description_number: u16 = 206;
const packed_bits_max: u32 = value_module.bits_max;
const sint8_invalid: u8 = 0x7F;
const timestamp_invalid: u32 = 0xFFFFFFFF;
const uint8_invalid: u8 = 0xFF;
const unknown_field_format = "field_{d}";
const unknown_message_name = "unknown";

const timestamp_meta: Meta = .{
    .name = "timestamp",
    .offset = 0.0,
    .scale = 1.0,
    .type_index = null,
    .type_name = "date_time",
    .units = "",
};

comptime {
    assert(packed_bits_max == 64);
    assert(std.fmt.count(developer_name_format, .{ 255, 255 }) <= name_bytes_max);
    assert(std.fmt.count(unknown_field_format, .{255}) <= name_bytes_max);
    assert(uint8_invalid == BaseType.uint8.invalid_value().?);
    assert(sint8_invalid == BaseType.sint8.invalid_value().?);
}

fn field_value(raw: *const RawField, meta: *const Meta) Decoder.Value {
    assert(meta.scale != 0.0);
    assert(raw.bytes.len <= parser_module.field_bytes_max);

    const base = raw.base_type;
    const element = base.size_bytes();

    if (raw.bytes.len == 0) return .none;
    if (base == .string) return value_module.decode(raw, meta);

    if (base == .byte) {
        if (raw.bytes.len != 1) return .{ .bytes = raw.bytes };
    }

    if (raw.bytes.len == element) return value_module.decode(raw, meta);
    if (raw.bytes.len < element) return .none;

    const count = @divFloor(raw.bytes.len, element);

    const array: Decoder.Value.Array = .{
        .architecture = raw.architecture,
        .base_type = base,
        .bytes = raw.bytes[0 .. count * element],
        .offset = meta.offset,
        .scale = meta.scale,
    };

    assert(array.count() == count);

    if (base.is_float()) return .{ .real_array = array };
    if (meta.scale != 1.0) return .{ .real_array = array };
    if (meta.offset != 0.0) return .{ .real_array = array };
    return .{ .integer_array = array };
}

fn supplement_meta(message: *const DataMessage, raw: *const RawField) Meta {
    assert(garmin.field_supplements.len > 0);
    assert(raw.architecture == message.architecture);

    if (raw.number == parser_module.timestamp_field_number) return timestamp_meta;

    const found = garmin.field_supplement(message.global_number, raw.number) orelse
        return value_module.plain;

    assert(found.global_number == message.global_number);

    return .{
        .name = found.name,
        .offset = 0.0,
        .scale = found.scale,
        .type_index = null,
        .type_name = found.type_name,
        .units = found.units,
    };
}

fn accumulates(raw: *const RawField, field: *const profile.Field) bool {
    assert(field.name.len > 0);
    assert(raw.bytes.len <= parser_module.field_bytes_max);

    if (!field.accumulate) return false;
    if (raw.bytes.len != raw.base_type.size_bytes()) return false;
    return raw.bytes.len < value_module.bytes_max;
}

fn accumulator_key(identity: *const FieldIdentity) u32 {
    const result = (@as(u32, identity.global_number) << 8) | identity.field_number;

    assert(result >> 8 == identity.global_number);
    assert(result & 0xFF == identity.field_number);

    return result;
}

fn developer_key(identity: *const DeveloperIdentity) u16 {
    const result = (@as(u16, identity.developer_data_index) << 8) | identity.number;

    assert(result >> 8 == identity.developer_data_index);
    assert(result & 0xFF == identity.number);

    return result;
}

fn scalar_u8(field: *const RawField) ?u8 {
    assert(field.bytes.len <= parser_module.field_bytes_max);

    if (field.bytes.len == 0) return null;
    if (field.bytes[0] == uint8_invalid) return null;
    return field.bytes[0];
}

fn scalar_i8(field: *const RawField) ?i8 {
    assert(field.bytes.len <= parser_module.field_bytes_max);

    if (field.bytes.len == 0) return null;
    if (field.bytes[0] == sint8_invalid) return null;

    const result: i8 = @bitCast(field.bytes[0]);

    assert(result != std.math.maxInt(i8));

    return result;
}

fn scaled_unsigned(reading: *const Reading) Decoder.Value {
    assert(reading.scale != 0.0);
    assert(std.math.isFinite(reading.offset));

    const real: f64 = @floatFromInt(reading.raw);
    const scaled: Decoder.Value = .{ .real = real / reading.scale - reading.offset };

    if (reading.scale != 1.0) return scaled;
    if (reading.offset != 0.0) return scaled;
    return .{ .unsigned = reading.raw };
}

test StorageType {
    const Fixed = StorageType(.{
        .accumulator_count_max = 2,
        .developer_field_count_max = 3,
        .field_count_max = 4,
        .text_bytes_max = 5,
    });

    var fixed: Fixed = undefined;

    const storage = fixed.slices();

    try std.testing.expectEqual(@as(usize, 2), storage.accumulators.len);
    try std.testing.expectEqual(@as(usize, 3), storage.descriptions.len);
    try std.testing.expectEqual(@as(usize, 4), storage.fields.len);
    try std.testing.expectEqual(storage.fields.len, storage.names.len);
    try std.testing.expectEqual(@as(usize, 5), storage.text.len);
}

const TestDecoder = DecoderType(.{
    .accumulator_count_max = 4,
    .developer_field_count_max = 4,
    .field_count_max = 16,
    .text_bytes_max = 64,
});

test DecoderType {
    const bytes = [_]u8{
        12,   0x20, 0x8F, 0x08,
        14,   0x00, 0x00, 0x00,
        '.',  'F',  'I',  'T',
        0x40, 0x00, 0x00, 0x14,
        0x00, 0x01, 0xFD, 0x04,
        0x86, 0x00, 0x00, 0xCA,
        0x9A, 0x3B,
    };

    var decoder: TestDecoder = undefined;

    try decoder.init(&bytes);

    const message = (try decoder.next()).message;

    try std.testing.expectEqualStrings("record", message.name);
    try std.testing.expectEqual(@as(?u32, 1_000_000_000), message.timestamp);
    try std.testing.expectEqual(@as(usize, 1), message.fields.len);
    try std.testing.expectEqualStrings("timestamp", message.fields[0].name);
    const trailing = try decoder.next();

    try std.testing.expect(trailing == .end);
}

test Decoder {
    const bytes = [_]u8{
        12,   0x20, 0x8F, 0x08,
        12,   0x00, 0x00, 0x00,
        '.',  'F',  'I',  'T',
        0x40, 0x00, 0x00, 0x14,
        0x00, 0x01, 0x06, 0x02,
        0x84, 0x00, 0xD0, 0x07,
    };

    var storage: StorageType(.{
        .accumulator_count_max = 1,
        .developer_field_count_max = 1,
        .field_count_max = 4,
        .text_bytes_max = 16,
    }) = undefined;

    var decoder: Decoder = undefined;

    try decoder.init(storage.slices(), &bytes);

    const message = (try decoder.next()).message;

    try std.testing.expectEqual(@as(usize, 2), message.fields.len);
    try std.testing.expectEqualStrings("speed", message.fields[0].name);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), message.fields[0].value.real, 1e-9);
    try std.testing.expectEqualStrings("enhanced_speed", message.fields[1].name);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), message.fields[1].value.real, 1e-9);
}

test "the decoder reads array fields element by element" {
    const bytes = [_]u8{
        12,   0x20, 0x8F, 0x08,
        13,   0x00, 0x00, 0x00,
        '.',  'F',  'I',  'T',
        0x40, 0x00, 0x00, 0x14,
        0x00, 0x01, 0xC8, 0x03,
        0x02, 0x00, 0x0A, 0x14,
        0x1E,
    };

    var decoder: TestDecoder = undefined;

    try decoder.init(&bytes);

    const message = (try decoder.next()).message;

    try std.testing.expectEqual(@as(usize, 1), message.fields.len);

    const array = message.fields[0].value.integer_array;

    try std.testing.expectEqual(@as(u32, 3), array.count());
    try std.testing.expectEqual(@as(i64, 10), array.integer_of(0));
    try std.testing.expectEqual(@as(i64, 20), array.integer_of(1));
    try std.testing.expectEqual(@as(i64, 30), array.integer_of(2));
}

test "the decoder chains multiple FIT files" {
    const file = [_]u8{
        12,   0x20, 0x8F, 0x08,
        14,   0x00, 0x00, 0x00,
        '.',  'F',  'I',  'T',
        0x40, 0x00, 0x00, 0x14,
        0x00, 0x01, 0xFD, 0x04,
        0x86, 0x00, 0x00, 0xCA,
        0x9A, 0x3B, 0x00, 0x00,
    };

    const bytes = file ++ file;

    var decoder: TestDecoder = undefined;

    try decoder.init(&bytes);

    for (0..2) |_| {
        const message = (try decoder.next()).message;

        try std.testing.expectEqualStrings("record", message.name);
    }

    const trailing = try decoder.next();

    try std.testing.expect(trailing == .end);
}

test "the decoder resolves developer fields through field_description" {
    const bytes = [_]u8{
        12,   0x20, 0x8F, 0x08,
        52,   0x00, 0x00, 0x00,
        '.',  'F',  'I',  'T',
        0x40, 0x00, 0x00, 0xCE,
        0x00, 0x05, 0x00, 0x01,
        0x02, 0x01, 0x01, 0x02,
        0x02, 0x01, 0x02, 0x03,
        0x06, 0x07, 0x08, 0x02,
        0x07, 0x00, 0x00, 0x00,
        0x02, 'p',  'o',  'w',
        'e',  'r',  0x00, 'W',
        0x00, 0x61, 0x00, 0x00,
        0x14, 0x00, 0x01, 0xFD,
        0x04, 0x86, 0x01, 0x00,
        0x01, 0x00, 0x01, 0x00,
        0xCA, 0x9A, 0x3B, 0xFA,
    };

    var decoder: TestDecoder = undefined;

    try decoder.init(&bytes);

    const description = (try decoder.next()).message;

    try std.testing.expectEqualStrings("field_description", description.name);

    const record = (try decoder.next()).message;

    try std.testing.expectEqualStrings("record", record.name);

    const power = for (record.fields) |field| {
        if (std.mem.eql(u8, field.name, "power")) break field;
    } else return error.TestUnexpectedResult;

    try std.testing.expectEqual(@as(u64, 250), power.value.unsigned);
    try std.testing.expectEqualStrings("W", power.units);
    const trailing = try decoder.next();

    try std.testing.expect(trailing == .end);
}

test "the decoder names a developer field described without a name by its identity" {
    const bytes = [_]u8{
        12,   0x20, 0x8F, 0x08,
        38,   0x00, 0x00, 0x00,
        '.',  'F',  'I',  'T',
        0x40, 0x00, 0x00, 0xCE,
        0x00, 0x03, 0x00, 0x01,
        0x02, 0x01, 0x01, 0x02,
        0x02, 0x01, 0x02, 0x00,
        0x00, 0x03, 0x02, 0x61,
        0x00, 0x00, 0x14, 0x00,
        0x01, 0xFD, 0x04, 0x86,
        0x01, 0x03, 0x01, 0x00,
        0x01, 0x00, 0xCA, 0x9A,
        0x3B, 0xFA,
    };

    var decoder: TestDecoder = undefined;

    try decoder.init(&bytes);

    const description = (try decoder.next()).message;

    try std.testing.expectEqualStrings("field_description", description.name);

    const record = (try decoder.next()).message;

    try std.testing.expectEqual(@as(usize, 2), record.fields.len);
    try std.testing.expectEqualStrings("dev_0_3", record.fields[1].name);
    try std.testing.expectEqual(@as(u64, 250), record.fields[1].value.unsigned);
    const trailing = try decoder.next();

    try std.testing.expect(trailing == .end);
}

test "accumulation reconstructs rolling totals across rollover and per key" {
    const bytes = [_]u8{ 12, 0x20, 0x8F, 0x08, 0, 0, 0, 0, '.', 'F', 'I', 'T' };

    var decoder: TestDecoder = undefined;

    try decoder.init(&bytes);

    const inner = &decoder.base;

    try std.testing.expectEqual(@as(u64, 10), try inner.accumulate(1, 10, 8));
    try std.testing.expectEqual(@as(u64, 250), try inner.accumulate(1, 250, 8));
    try std.testing.expectEqual(@as(u64, 261), try inner.accumulate(1, 5, 8));
    try std.testing.expectEqual(@as(u64, 9), try inner.accumulate(2, 9, 8));
    try std.testing.expectEqual(@as(u64, 262), try inner.accumulate(1, 6, 8));

    const wide = try inner.accumulate(3, std.math.maxInt(u64), 64);

    try std.testing.expectEqual(std.math.maxInt(u64), wide);
    try std.testing.expectEqual(@as(u64, 7), try inner.accumulate(4, 7, 8));
    try std.testing.expectError(error.AccumulatorsExhausted, inner.accumulate(5, 1, 8));
}

test "a message with more fields than the capacity is refused with its offset" {
    const bytes = [_]u8{
        12,   0x20, 0x8F, 0x08,
        12,   0x00, 0x00, 0x00,
        '.',  'F',  'I',  'T',
        0x40, 0x00, 0x00, 0x14,
        0x00, 0x01, 0x06, 0x02,
        0x84, 0x00, 0xD0, 0x07,
    };

    var storage: StorageType(.{
        .accumulator_count_max = 1,
        .developer_field_count_max = 1,
        .field_count_max = 1,
        .text_bytes_max = 1,
    }) = undefined;

    var decoder: Decoder = undefined;

    try decoder.init(storage.slices(), &bytes);
    const result = decoder.next();

    try std.testing.expectError(error.FieldsExhausted, result);
    try std.testing.expectEqual(@as(u32, 21), decoder.diagnostic.offset);
}

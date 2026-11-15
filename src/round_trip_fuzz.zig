const std = @import("std");

const encoder_module = @import("encoder.zig");
const fuzz = @import("testing/fuzz.zig");
const parser_module = @import("parser.zig");
const profile = @import("profile.zig");

const assert = std.debug.assert;

const BaseType = @import("base_type.zig").BaseType;
const DecoderType = @import("decoder.zig").DecoderType;
const Encoder = encoder_module.Encoder;
const Parser = parser_module.Parser;
const ValueTag = std.meta.Tag(Encoder.Value);

const Decoder = DecoderType(.{
    .accumulator_count_max = profile.accumulator_count_max,
    .developer_field_count_max = message_count_generated_max,
    .field_count_max = field_count_generated_max * (3 + profile.component_count_max),
    .text_bytes_max = message_count_generated_max * 2 * encoder_module.string_bytes_max,
});

const State = struct {
    decoder: Decoder,
    encoded: [encoded_bytes_max]u8,
    fields: [message_count_generated_max][field_count_generated_max]Encoder.Field,
    message_count: u32,
    messages: [message_count_generated_max]Encoder.Message,
    parser: Parser,
    strings: [message_count_generated_max][field_count_generated_max]Text,
};

const Text = [encoder_module.string_bytes_max]u8;

const field_count_generated_max: u32 = 32;
const message_count_generated_max: u32 = 64;
const string_bytes_generated_max: u32 = 32;

const encoded_bytes_max: u32 = parser_module.header_bytes_min + 2 +
    message_count_generated_max * (6 + 3 * field_count_generated_max + 1 +
        field_count_generated_max * parser_module.field_bytes_max);

const globals_pool = [_]u16{ 0, 18, 19, 20, 21, 34, 78, 104, 206, 233 };

comptime {
    assert(field_count_generated_max <= parser_module.field_count_max);
    assert(string_bytes_generated_max < encoder_module.string_bytes_max);
    assert(encoded_bytes_max <= parser_module.source_bytes_max);
}

pub fn run(gpa: std.mem.Allocator, campaign: *const fuzz.Campaign) !void {
    assert(campaign.events_max >= 1);
    assert(campaign.events_max <= fuzz.events_max_limit);

    const state = try init(gpa);
    defer gpa.destroy(state);

    var prng = std.Random.DefaultPrng.init(campaign.seed);

    for (0..campaign.events_max) |_| try event_run(state, prng.random());
}

fn init(gpa: std.mem.Allocator) !*State {
    assert(encoded_bytes_max > 0);

    const result = try gpa.create(State);

    assert(result.messages.len == message_count_generated_max);

    return result;
}

fn event_run(state: *State, random: std.Random) !void {
    assert(state.encoded.len == encoded_bytes_max);

    messages_generate(state, random);

    var encoder: Encoder = undefined;

    encoder.init(&state.encoded);

    const messages = state.messages[0..state.message_count];

    for (messages) |*message| try encoder.write_message(message);

    const bytes = encoder.close();

    assert(bytes.len >= parser_module.header_bytes_min + 2);

    try parser_module.verify_checksum(bytes);
    try parser_check(&state.parser, messages, bytes);
    try decoder_check(&state.decoder, state.message_count, bytes);
}

fn messages_generate(state: *State, random: std.Random) void {
    assert(state.messages.len == message_count_generated_max);

    state.message_count = 1 + random.uintLessThan(u32, message_count_generated_max);

    for (0..state.message_count) |index| {
        const field_count = random.uintAtMost(u32, field_count_generated_max);
        const fields = state.fields[index][0..field_count];

        for (fields, 0..) |*field, position| {
            field.* = .{
                .number = random.int(u8),
                .value = value_generate(&state.strings[index][position], random),
            };
        }

        state.messages[index] = .{
            .fields = fields,
            .global_number = global_pick(random),
        };
    }

    assert(state.message_count <= message_count_generated_max);
}

fn global_pick(random: std.Random) u16 {
    assert(globals_pool.len > 0);

    if (random.boolean()) return globals_pool[random.uintLessThan(u32, globals_pool.len)];
    return random.int(u16);
}

fn value_generate(text: *[encoder_module.string_bytes_max]u8, random: std.Random) Encoder.Value {
    assert(text.len == encoder_module.string_bytes_max);

    const result: Encoder.Value = switch (random.enumValue(ValueTag)) {
        .enum_value => .{ .enum_value = random.int(u8) },
        .uint8 => .{ .uint8 = random.int(u8) },
        .uint16 => .{ .uint16 = random.int(u16) },
        .uint32 => .{ .uint32 = random.int(u32) },
        .sint8 => .{ .sint8 = random.int(i8) },
        .sint16 => .{ .sint16 = random.int(i16) },
        .sint32 => .{ .sint32 = random.int(i32) },
        .float32 => .{ .float32 = @bitCast(random.int(u32)) },
        .float64 => .{ .float64 = @bitCast(random.int(u64)) },
        .string => .{ .string = string_generate(text, random) },
    };

    return result;
}

fn string_generate(text: *[encoder_module.string_bytes_max]u8, random: std.Random) []const u8 {
    assert(text.len == encoder_module.string_bytes_max);

    const length: u32 = switch (random.int(u2)) {
        0 => 0,
        1 => encoder_module.string_bytes_max,
        else => random.uintAtMost(u32, string_bytes_generated_max),
    };

    for (text[0..length]) |*byte| byte.* = random.intRangeAtMost(u8, 1, 255);

    const result = text[0..length];

    assert(std.mem.findScalar(u8, result, 0) == null);

    return result;
}

fn parser_check(parser: *Parser, messages: []const Encoder.Message, bytes: []const u8) !void {
    assert(messages.len <= message_count_generated_max);
    assert(bytes.len <= encoded_bytes_max);

    try parser.init(bytes);

    for (messages) |*message| {
        const decoded = (try parser.next()).message;

        assert(decoded.global_number == message.global_number);
        assert(decoded.architecture == .little);

        var fields = decoded.fields();

        for (message.fields) |*expected| {
            const actual = fields.next() orelse unreachable;

            assert(actual.number == expected.number);

            field_check(&expected.value, actual);
        }

        const trailing_field = fields.next();

        assert(trailing_field == null);
    }

    const trailing = try parser.next();

    assert(trailing == .end);
}

fn field_check(expected: *const Encoder.Value, actual: Parser.Field) void {
    assert(actual.bytes.len <= parser_module.field_bytes_max);

    const base = base_type_of(expected);

    assert(actual.base_type == base);

    if (expected.* != .string) assert(actual.bytes.len == base.size_bytes());

    const bytes = actual.bytes;

    switch (expected.*) {
        .enum_value, .uint8 => |value| assert(bytes[0] == value),
        .sint8 => |value| assert(@as(i8, @bitCast(bytes[0])) == value),
        .uint16 => |value| assert(std.mem.readInt(u16, bytes[0..2], .little) == value),
        .sint16 => |value| assert(std.mem.readInt(i16, bytes[0..2], .little) == value),
        .uint32 => |value| assert(std.mem.readInt(u32, bytes[0..4], .little) == value),
        .sint32 => |value| assert(std.mem.readInt(i32, bytes[0..4], .little) == value),
        .float32 => |value| {
            const bits: u32 = @bitCast(value);

            assert(std.mem.readInt(u32, bytes[0..4], .little) == bits);
        },
        .float64 => |value| {
            const bits: u64 = @bitCast(value);

            assert(std.mem.readInt(u64, bytes[0..8], .little) == bits);
        },
        .string => |text| {
            assert(bytes.len == text.len + 1);
            assert(std.mem.eql(u8, bytes[0..text.len], text));
            assert(bytes[text.len] == 0);
        },
    }
}

fn base_type_of(value: *const Encoder.Value) BaseType {
    const result: BaseType = switch (value.*) {
        .enum_value => .enum_value,
        .uint8 => .uint8,
        .uint16 => .uint16,
        .uint32 => .uint32,
        .sint8 => .sint8,
        .sint16 => .sint16,
        .sint32 => .sint32,
        .float32 => .float32,
        .float64 => .float64,
        .string => .string,
    };

    assert(result != .byte);
    assert((result == .string) == (value.* == .string));

    return result;
}

fn decoder_check(decoder: *Decoder, message_count: u32, bytes: []const u8) !void {
    assert(message_count <= message_count_generated_max);
    assert(bytes.len <= encoded_bytes_max);

    try decoder.init(bytes);

    var count: u32 = 0;

    for (0..message_count + 1) |_| {
        const message = switch (try decoder.next()) {
            .end => break,
            .message => |message| message,
        };

        count += 1;

        assert(message.name.len > 0);

        std.mem.doNotOptimizeAway(message.fields.len);
    }

    assert(count == message_count);
}

test run {
    try run(std.testing.allocator, &.{ .events_max = 8, .seed = 0x2f17_f5ed });
}

const std = @import("std");

const fit = @import("fit.zig");

const assert = std.debug.assert;

const Encoder = fit.Encoder;
const Parser = fit.Parser;
const ValueTag = std.meta.Tag(Encoder.Value);

const Messages = struct {
    count: u32,
    fields: [message_count_max][field_count_max]Encoder.Field,
    messages: [message_count_max]Encoder.Message,
    strings: [message_count_max][field_count_max][string_bytes_max]u8,
};

const State = struct {
    encoded: [file_bytes_max]u8,
    generated: Messages,
    parser: Parser,
};

const field_count_max: u32 = 8;
const file_bytes_max: u32 = 1 << 16;
const message_count_max: u32 = 16;
const round_count: u32 = 64;
const string_bytes_max: u32 = 12;

fn round_trip_check(state: *State, random: std.Random) !void {
    assert(state.encoded.len == file_bytes_max);

    messages_random(&state.generated, random);

    var encoder: Encoder = undefined;

    encoder.init(&state.encoded);

    const messages = state.generated.messages[0..state.generated.count];

    for (messages) |*message| try encoder.write_message(message);

    const bytes = encoder.close();

    try fit.verify_checksum(bytes);
    try state.parser.init(bytes);

    for (messages) |*message| {
        const decoded = (try state.parser.next()).message;

        try std.testing.expectEqual(message.global_number, decoded.global_number);

        var fields = decoded.fields();

        for (message.fields) |*expected| {
            const actual = fields.next() orelse return error.TestUnexpectedResult;

            try std.testing.expectEqual(expected.number, actual.number);
            try field_bytes_expect(&expected.value, &actual);
        }

        const field_trailing = fields.next();

        try std.testing.expect(field_trailing == null);
    }

    const trailing = try state.parser.next();

    try std.testing.expect(trailing == .end);
}

fn messages_random(generated: *Messages, random: std.Random) void {
    assert(generated.messages.len == message_count_max);

    generated.count = random.intRangeAtMost(u32, 1, message_count_max);

    for (0..generated.count) |index| {
        const field_count = random.intRangeAtMost(u32, 0, field_count_max);
        const fields = generated.fields[index][0..field_count];

        for (fields, 0..) |*field, position| {
            field.* = .{
                .number = random.int(u8),
                .value = value_random(&generated.strings[index][position], random),
            };
        }

        generated.messages[index] = .{ .fields = fields, .global_number = random.int(u16) };
    }
}

fn value_random(text: *[string_bytes_max]u8, random: std.Random) Encoder.Value {
    assert(text.len == string_bytes_max);

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
        .string => .{ .string = string_random(text, random) },
    };

    return result;
}

fn string_random(text: *[string_bytes_max]u8, random: std.Random) []const u8 {
    assert(text.len == string_bytes_max);

    const length = random.intRangeAtMost(u32, 0, string_bytes_max);

    for (text[0..length]) |*byte| byte.* = random.intRangeAtMost(u8, 1, 255);

    const result = text[0..length];

    assert(std.mem.findScalar(u8, result, 0) == null);

    return result;
}

fn field_bytes_expect(expected: *const Encoder.Value, actual: *const Parser.Field) !void {
    const bytes = actual.bytes;

    switch (expected.*) {
        .enum_value, .uint8 => |value| {
            try std.testing.expectEqual(@as(usize, 1), bytes.len);
            try std.testing.expectEqual(value, bytes[0]);
        },
        .sint8 => |value| {
            try std.testing.expectEqual(@as(usize, 1), bytes.len);
            try std.testing.expectEqual(value, @as(i8, @bitCast(bytes[0])));
        },
        .uint16 => |value| {
            try std.testing.expectEqual(value, std.mem.readInt(u16, bytes[0..2], .little));
        },
        .sint16 => |value| {
            try std.testing.expectEqual(value, std.mem.readInt(i16, bytes[0..2], .little));
        },
        .uint32 => |value| {
            try std.testing.expectEqual(value, std.mem.readInt(u32, bytes[0..4], .little));
        },
        .sint32 => |value| {
            try std.testing.expectEqual(value, std.mem.readInt(i32, bytes[0..4], .little));
        },
        .float32 => |value| {
            const bits: u32 = @bitCast(value);

            try std.testing.expectEqual(bits, std.mem.readInt(u32, bytes[0..4], .little));
        },
        .float64 => |value| {
            const bits: u64 = @bitCast(value);

            try std.testing.expectEqual(bits, std.mem.readInt(u64, bytes[0..8], .little));
        },
        .string => |text| {
            try std.testing.expectEqual(text.len + 1, bytes.len);
            try std.testing.expectEqualSlices(u8, text, bytes[0..text.len]);
            try std.testing.expectEqual(@as(u8, 0), bytes[text.len]);
        },
    }
}

test "random messages survive an encode and parse round trip" {
    const state = try std.testing.allocator.create(State);
    defer std.testing.allocator.destroy(state);

    var prng = std.Random.DefaultPrng.init(0x2f17_5eed);

    for (0..round_count) |_| try round_trip_check(state, prng.random());
}

test "definitions beyond the local type budget evict and re-encode" {
    const state = try std.testing.allocator.create(State);
    defer std.testing.allocator.destroy(state);

    const definition_count = 2 * 16 + 1;

    var encoder: Encoder = undefined;

    encoder.init(&state.encoded);

    for (0..definition_count) |position| {
        const number: u8 = @intCast(position);
        const fields = [_]Encoder.Field{.{ .number = number, .value = .{ .uint8 = number } }};

        try encoder.write_message(&.{ .fields = &fields, .global_number = number });
    }

    const revisit = [_]Encoder.Field{.{ .number = 0, .value = .{ .uint8 = 0xAB } }};

    try encoder.write_message(&.{ .fields = &revisit, .global_number = 0 });

    const bytes = encoder.close();

    try fit.verify_checksum(bytes);
    try state.parser.init(bytes);

    for (0..definition_count + 1) |decoded| {
        const message = (try state.parser.next()).message;
        const expected: u16 = if (decoded < definition_count) @intCast(decoded) else 0;

        try std.testing.expectEqual(expected, message.global_number);
    }

    const trailing = try state.parser.next();

    try std.testing.expect(trailing == .end);
}

const std = @import("std");

const crc = @import("crc.zig");
const fuzz = @import("testing/fuzz.zig");
const parser_module = @import("parser.zig");
const profile = @import("profile.zig");

const assert = std.debug.assert;

const BaseType = @import("base_type.zig").BaseType;
const DecoderType = @import("decoder.zig").DecoderType;
const Parser = parser_module.Parser;

const Decoder = DecoderType(.{
    .accumulator_count_max = profile.accumulator_count_max,
    .developer_field_count_max = chained_file_count_generated_max * operation_count_generated_max,
    .field_count_max = field_count_generated_max * (3 + profile.component_count_max) +
        developer_count_generated_max,
    .text_bytes_max = chained_file_count_generated_max * operation_count_generated_max * 512,
});

const Generated = struct {
    message_count: u32,
    size_bytes: u32,
};

const Generator = struct {
    body: [body_bytes_generated_max]u8,
    count: u32,
    locals: [parser_module.local_type_count]?u32,
    random: std.Random,

    fn operation_emit(generator: *Generator, weights: Weights) u32 {
        assert(weights.define + weights.data > 0);
        assert(generator.count <= body_bytes_generated_max - operation_bytes_max);

        const any = generator.defined_pick(parser_module.local_type_count) orelse {
            generator.definition_emit();

            return 0;
        };

        const total = @as(u32, weights.define) + weights.data + weights.compressed;
        const roll = generator.random.uintLessThan(u32, total);

        if (roll < weights.define) {
            generator.definition_emit();

            return 0;
        }

        if (roll < @as(u32, weights.define) + weights.data) {
            generator.data_emit(any);

            return 1;
        }

        const low = generator.defined_pick(compressed_local_count) orelse {
            generator.data_emit(any);

            return 1;
        };

        generator.compressed_emit(low);

        return 1;
    }

    fn defined_pick(generator: *Generator, limit: u32) ?u4 {
        assert(limit >= 1);
        assert(limit <= parser_module.local_type_count);

        var candidates: [parser_module.local_type_count]u4 = undefined;
        var count: u32 = 0;

        for (generator.locals[0..limit], 0..) |slot, index| {
            if (slot != null) {
                candidates[count] = @intCast(index);
                count += 1;
            }
        }

        if (count == 0) return null;
        return candidates[generator.random.uintLessThan(u32, count)];
    }

    fn global_pick(generator: *Generator) u16 {
        assert(globals_pool.len > 0);
        assert(generator.count <= body_bytes_generated_max);

        if (generator.random.boolean()) {
            return globals_pool[generator.random.uintLessThan(u32, globals_pool.len)];
        }

        return generator.random.int(u16);
    }

    fn definition_emit(generator: *Generator) void {
        assert(generator.count <= body_bytes_generated_max - definition_bytes_max);

        const local = generator.random.int(u4);
        const developer = generator.random.int(u2) == 0;

        const record: parser_module.RecordHeader = .{
            .local_message_type = local,
            .reserved = 0,
            .developer_data = @intFromBool(developer),
            .message_kind = .definition,
            .header_kind = .normal,
        };

        generator.byte_emit(@bitCast(record));
        generator.byte_emit(generator.random.int(u8));

        const big = generator.random.boolean();
        const architecture: std.lang.Endian = if (big) .big else .little;

        var global_bytes: [2]u8 = undefined;

        std.mem.writeInt(u16, &global_bytes, generator.global_pick(), architecture);

        generator.byte_emit(@intFromBool(big));
        generator.slice_emit(&global_bytes);

        const field_count = generator.random.uintAtMost(u8, @intCast(field_count_generated_max));

        generator.byte_emit(field_count);

        var payload: u32 = 0;

        for (0..field_count) |_| payload += generator.field_definition_emit();

        if (developer) payload += generator.developer_definitions_emit();

        assert(payload <= payload_bytes_generated_max);

        generator.locals[local] = payload;
    }

    fn field_definition_emit(generator: *Generator) u32 {
        assert(generator.count + 3 <= body_bytes_generated_max);

        const number = if (generator.random.int(u2) == 0)
            parser_module.timestamp_field_number
        else
            generator.random.int(u8);

        const base = generator.random.enumValue(BaseType);
        const element = base.size_bytes();

        const size: u8 = switch (generator.random.int(u2)) {
            0 => element,
            1 => element * (1 + generator.random.uintLessThan(u8, 4)),
            2 => generator.random.int(u8),
            3 => 0,
        };

        generator.byte_emit(number);
        generator.byte_emit(size);
        generator.byte_emit(@backingInt(base));

        assert(generator.body[generator.count - 2] == size);

        return size;
    }

    fn developer_definitions_emit(generator: *Generator) u32 {
        assert(generator.count + 1 + 3 * developer_count_generated_max <= body_bytes_generated_max);

        const count = generator.random.uintAtMost(u8, @intCast(developer_count_generated_max));

        generator.byte_emit(count);

        var total: u32 = 0;

        for (0..count) |_| {
            const size_wide = generator.random.uintAtMost(u32, developer_field_bytes_generated_max);
            const size: u8 = @intCast(size_wide);

            generator.byte_emit(generator.random.int(u8));
            generator.byte_emit(size);
            generator.byte_emit(generator.random.uintAtMost(u8, 3));

            total += size;
        }

        assert(total <= developer_count_generated_max * developer_field_bytes_generated_max);

        return total;
    }

    fn data_emit(generator: *Generator, local: u4) void {
        assert(generator.locals[local] != null);

        const record: parser_module.RecordHeader = .{
            .local_message_type = local,
            .reserved = 0,
            .developer_data = 0,
            .message_kind = .data,
            .header_kind = .normal,
        };

        generator.byte_emit(@bitCast(record));
        generator.payload_emit(generator.locals[local].?);
    }

    fn compressed_emit(generator: *Generator, local: u4) void {
        assert(local < compressed_local_count);
        assert(generator.locals[local] != null);

        const offset = generator.random.int(u5);
        const header = compressed_header_bit | (@as(u8, local) << 5) | offset;

        generator.byte_emit(header);
        generator.payload_emit(generator.locals[local].?);
    }

    fn payload_emit(generator: *Generator, size: u32) void {
        assert(size <= payload_bytes_generated_max);
        assert(generator.count + size <= body_bytes_generated_max);

        generator.random.bytes(generator.body[generator.count..][0..size]);
        generator.count += size;
    }

    fn byte_emit(generator: *Generator, byte: u8) void {
        assert(generator.count < body_bytes_generated_max);

        generator.body[generator.count] = byte;
        generator.count += 1;

        assert(generator.body[generator.count - 1] == byte);
    }

    fn slice_emit(generator: *Generator, bytes: []const u8) void {
        assert(bytes.len <= operation_bytes_max);
        assert(generator.count + bytes.len <= body_bytes_generated_max);

        @memcpy(generator.body[generator.count..][0..bytes.len], bytes);
        generator.count += @intCast(bytes.len);
    }
};

const State = struct {
    decoder: Decoder,
    file: [file_bytes_generated_max]u8,
    generator: Generator,
    mutated: [file_bytes_generated_max]u8,
    parser: Parser,
};

const Weights = struct {
    compressed: u8,
    data: u8,
    define: u8,
};

const body_bytes_generated_max: u32 = operation_count_generated_max * operation_bytes_max;
const chained_file_count_generated_max: u32 = 3;
const compressed_header_bit: u8 = 0x80;
const compressed_local_count: u32 = 4;
const definition_bytes_max: u32 = 6 + 3 * field_count_generated_max + 1 +
    3 * developer_count_generated_max;

const developer_count_generated_max: u32 = 40;
const developer_field_bytes_generated_max: u32 = 16;
const field_count_generated_max: u32 = 8;
const mutation_flip_count_max: u32 = 16;
const mutation_round_count: u32 = 4;
const operation_bytes_max: u32 = @max(1 + payload_bytes_generated_max, definition_bytes_max);
const operation_count_generated_max: u32 = 64;

const file_bytes_generated_max: u32 = chained_file_count_generated_max *
    (parser_module.header_bytes_max + body_bytes_generated_max + crc.checksum_bytes);

const payload_bytes_generated_max: u32 = field_count_generated_max * parser_module.field_bytes_max +
    developer_count_generated_max * developer_field_bytes_generated_max;

const globals_pool = [_]u16{ 0, 18, 19, 20, 21, 34, 78, 104, 206, 233 };

comptime {
    assert(compressed_header_bit == 1 << 7);
    assert(compressed_local_count == std.math.maxInt(u2) + 1);
    assert(compressed_local_count <= parser_module.local_type_count);
    assert(payload_bytes_generated_max <= parser_module.payload_bytes_max);
    assert(file_bytes_generated_max <= parser_module.source_bytes_max);
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
    assert(file_bytes_generated_max > 0);

    const result = try gpa.create(State);

    assert(result.file.len == file_bytes_generated_max);

    return result;
}

fn event_run(state: *State, random: std.Random) !void {
    assert(state.file.len == file_bytes_generated_max);
    assert(state.mutated.len == file_bytes_generated_max);

    const generated = generate(state, random);
    const bytes = state.file[0..generated.size_bytes];

    assert(bytes.len >= parser_module.header_bytes_min + crc.checksum_bytes);

    try parser_check(&state.parser, bytes, generated.message_count);
    try decoder_check(&state.decoder, bytes, generated.message_count);

    for (0..mutation_round_count) |_| {
        const mutated = mutate(state.mutated[0..bytes.len], bytes, random);

        decode_survives(&state.decoder, mutated);
    }
}

fn generate(state: *State, random: std.Random) Generated {
    assert(state.file.len == file_bytes_generated_max);

    const chained_file_count = 1 + random.uintLessThan(u32, chained_file_count_generated_max);

    var result: Generated = .{ .message_count = 0, .size_bytes = 0 };

    for (0..chained_file_count) |_| {
        state.generator = .{
            .body = undefined,
            .count = 0,
            .locals = @splat(null),
            .random = random,
        };

        result.message_count += chained_file_generate(&state.generator);
        result.size_bytes += chained_file_wrap(state.file[result.size_bytes..], &state.generator);
    }

    assert(result.size_bytes <= file_bytes_generated_max);

    return result;
}

fn chained_file_generate(generator: *Generator) u32 {
    assert(generator.count == 0);

    const random = generator.random;

    const weights: Weights = .{
        .compressed = random.uintLessThan(u8, 4),
        .data = 1 + random.uintLessThan(u8, 8),
        .define = 1 + random.uintLessThan(u8, 8),
    };

    const operation_count = random.uintAtMost(u32, operation_count_generated_max);

    var result: u32 = 0;

    for (0..operation_count) |_| result += generator.operation_emit(weights);

    assert(generator.count <= body_bytes_generated_max);
    assert(result <= operation_count);

    return result;
}

fn chained_file_wrap(target: []u8, generator: *const Generator) u32 {
    assert(generator.count <= body_bytes_generated_max);
    assert(target.len >= parser_module.header_bytes_max + generator.count + crc.checksum_bytes);

    const random = generator.random;
    const with_crc = random.boolean();

    const header_size = if (with_crc)
        parser_module.header_bytes_max
    else
        parser_module.header_bytes_min;

    const header = target[0..header_size];
    const signature_end = parser_module.signature_offset + parser_module.signature_bytes;

    header[0] = header_size;
    header[1] = random.int(u8);

    std.mem.writeInt(u16, header[2..4], random.int(u16), .little);
    std.mem.writeInt(u32, header[4..8], generator.count, .little);
    @memcpy(header[parser_module.signature_offset..signature_end], parser_module.file_signature);

    if (with_crc) {
        const header_crc = if (random.boolean()) crc.checksum(header[0..12]) else 0;

        std.mem.writeInt(u16, header[12..14], header_crc, .little);
    }

    const body = generator.body[0..generator.count];

    @memcpy(target[header_size..][0..body.len], body);

    const end = header_size + generator.count;
    const trailer = crc.checksum(target[0..end]);

    std.mem.writeInt(u16, target[end..][0..crc.checksum_bytes], trailer, .little);

    const result = end + crc.checksum_bytes;

    assert(result == header_size + body.len + crc.checksum_bytes);

    return result;
}

fn parser_check(parser: *Parser, bytes: []const u8, message_count: u32) !void {
    assert(bytes.len <= file_bytes_generated_max);
    assert(message_count <= chained_file_count_generated_max * operation_count_generated_max);

    try parser.init(bytes);

    var count: u32 = 0;

    for (0..message_count + 1) |_| {
        const message = switch (try parser.next()) {
            .end => break,
            .message => |message| message,
        };

        count += 1;

        assert(count <= message_count);
        assert(message.payload.len == message.definition.payload_size_bytes);

        var fields = message.fields();

        for (0..parser_module.field_count_max) |_| {
            const field = fields.next() orelse break;

            std.mem.doNotOptimizeAway(field.bytes.len);
        }

        var developer_fields = message.developer_fields();

        for (0..parser_module.developer_field_count_max) |_| {
            const field = developer_fields.next() orelse break;

            std.mem.doNotOptimizeAway(field.bytes.len);
        }
    }

    assert(count == message_count);
}

fn decoder_check(decoder: *Decoder, bytes: []const u8, message_count: u32) !void {
    assert(bytes.len <= file_bytes_generated_max);
    assert(message_count <= chained_file_count_generated_max * operation_count_generated_max);

    try decoder.init(bytes);

    var count: u32 = 0;

    for (0..message_count + 1) |_| {
        const message = switch (try decoder.next()) {
            .end => break,
            .message => |message| message,
        };

        count += 1;

        assert(count <= message_count);
        assert(message.name.len > 0);

        std.mem.doNotOptimizeAway(message.fields.len);
    }

    assert(count == message_count);
}

fn mutate(target: []u8, bytes: []const u8, random: std.Random) []const u8 {
    assert(target.len == bytes.len);
    assert(bytes.len >= parser_module.header_bytes_min);

    @memcpy(target, bytes);

    const flips = 1 + random.uintLessThan(u32, mutation_flip_count_max);

    for (0..flips) |_| {
        const index = random.uintLessThan(u32, @intCast(target.len));

        target[index] ^= random.int(u8);
    }

    const length = if (random.int(u2) == 0)
        random.uintAtMost(u32, @intCast(target.len))
    else
        @as(u32, @intCast(target.len));

    assert(length <= target.len);

    return target[0..length];
}

fn decode_survives(decoder: *Decoder, bytes: []const u8) void {
    assert(bytes.len <= file_bytes_generated_max);

    decoder.init(bytes) catch return;

    for (0..bytes.len + 1) |_| {
        const found = decoder.next() catch return;

        const message = switch (found) {
            .end => return,
            .message => |message| message,
        };

        std.mem.doNotOptimizeAway(message.fields.len);
    }

    unreachable;
}

test run {
    try run(std.testing.allocator, &.{ .events_max = 8, .seed = 0xDEC0DE });
}

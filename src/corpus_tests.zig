const std = @import("std");

const fit = @import("root.zig");

const corpus_directory = ".data";
const file_bytes_max = 64 * 1024 * 1024;
const file_count_max = 4096;

fn decode_all(gpa: std.mem.Allocator, bytes: []const u8) !void {
    var reader = std.Io.Reader.fixed(bytes);
    var decoder = try fit.Decoder.init(&reader);
    var stream = fit.Stream.init(&decoder, gpa);
    defer stream.deinit();

    var message_arena_state = std.heap.ArenaAllocator.init(gpa);
    defer message_arena_state.deinit();

    var count: u32 = 0;

    while (count < fit.Decoder.message_count_max) : (count += 1) {
        _ = message_arena_state.reset(.retain_capacity);

        const message = switch (try stream.next(message_arena_state.allocator())) {
            .end => break,
            .message => |message| message,
        };

        std.mem.doNotOptimizeAway(message.fields.len);
    }

    try std.testing.expect(count > 0);
}

test "corpus: every .fit file passes checksum and decodes" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var dir = std.Io.Dir.cwd().openDir(io, corpus_directory, .{ .iterate = true }) catch
        return error.SkipZigTest;

    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    var file_arena_state = std.heap.ArenaAllocator.init(gpa);
    defer file_arena_state.deinit();

    var checked: u32 = 0;

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.ascii.endsWithIgnoreCase(entry.basename, ".fit")) continue;
        if (checked == file_count_max) break;

        checked += 1;

        _ = file_arena_state.reset(.retain_capacity);

        const arena = file_arena_state.allocator();

        const bytes = try entry.dir.readFileAlloc(
            io,
            entry.basename,
            arena,
            .limited(file_bytes_max),
        );

        try fit.verify_checksum(bytes);
        try decode_all(gpa, bytes);
    }

    try std.testing.expect(checked > 0);
}

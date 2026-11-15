const std = @import("std");

const decoder_fuzz = @import("decoder_fuzz.zig");
const fuzz = @import("testing/fuzz.zig");
const round_trip_fuzz = @import("round_trip_fuzz.zig");

const assert = std.debug.assert;

const Fuzzer = enum {
    canary,
    decoder,
    round_trip,
    smoke,
};

const Error = error{
    ArgumentsInvalid,
    CanaryTripped,
};

const arguments_count_max: u32 = 4;
const arguments_count_min: u32 = 2;
const canary_odds: u32 = 1024;
const seed_smoke: u64 = 123;
const usage = "usage: fuzz <canary|decoder|round_trip|smoke> [seed] [events]\n";

comptime {
    assert(canary_odds > 1);
    assert(arguments_count_min < arguments_count_max);
    assert(fuzz.events_max_smoke < fuzz.events_max_default);
}

pub fn main(init: std.process.Init) !void {
    assert(init.minimal.args.vector.len < std.math.maxInt(u32));
    assert(usage.len > 0);

    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (arguments.len < arguments_count_min) return usage_fail();
    if (arguments.len > arguments_count_max) return usage_fail();

    const fuzzer = std.meta.stringToEnum(Fuzzer, arguments[1]) orelse return usage_fail();
    const smoke = fuzzer == .smoke;

    const seed = if (arguments.len > 2)
        try fuzz.seed_parse(arguments[2])
    else if (smoke)
        seed_smoke
    else
        fuzz.seed_random(init.io);

    const events_max = if (arguments.len > 3)
        std.fmt.parseUnsigned(u32, arguments[3], 10) catch return usage_fail()
    else if (smoke)
        fuzz.events_max_smoke
    else
        fuzz.events_max_default;

    if (events_max == 0) return usage_fail();
    if (events_max > fuzz.events_max_limit) return usage_fail();

    std.debug.print("fuzzer={t} seed={d} events={d}\n", .{ fuzzer, seed, events_max });

    try run(init.gpa, fuzzer, &.{ .events_max = events_max, .seed = seed });
}

fn usage_fail() Error {
    assert(usage.len > 0);
    assert(arguments_count_min > 0);
    assert(std.mem.endsWith(u8, usage, "\n"));

    std.debug.print("{s}", .{usage});

    return error.ArgumentsInvalid;
}

fn run(gpa: std.mem.Allocator, fuzzer: Fuzzer, campaign: *const fuzz.Campaign) !void {
    assert(campaign.events_max >= 1);
    assert(campaign.events_max <= fuzz.events_max_limit);

    switch (fuzzer) {
        .canary => try canary_run(campaign),
        .decoder => try decoder_fuzz.run(gpa, campaign),
        .round_trip => try round_trip_fuzz.run(gpa, campaign),
        .smoke => {
            try decoder_fuzz.run(gpa, campaign);
            try round_trip_fuzz.run(gpa, campaign);
        },
    }
}

fn canary_run(campaign: *const fuzz.Campaign) Error!void {
    assert(campaign.events_max >= 1);
    assert(canary_odds > 1);

    var prng = std.Random.DefaultPrng.init(campaign.seed);
    const random = prng.random();

    for (0..campaign.events_max) |_| {
        if (random.uintLessThan(u32, canary_odds) == 0) return error.CanaryTripped;
    }
}

test run {
    try run(std.testing.allocator, .smoke, &.{
        .events_max = fuzz.events_max_smoke,
        .seed = seed_smoke,
    });

    for (std.enums.values(Fuzzer)) |fuzzer| {
        const parsed = std.meta.stringToEnum(Fuzzer, @tagName(fuzzer));

        try std.testing.expect(std.mem.find(u8, usage, @tagName(fuzzer)) != null);
        try std.testing.expectEqual(@as(?Fuzzer, fuzzer), parsed);
    }
}

test canary_run {
    try canary_run(&.{ .events_max = 1, .seed = seed_smoke });

    var tripped: ?u64 = null;

    for (0..64) |seed| {
        canary_run(&.{ .events_max = 4096, .seed = seed }) catch {
            tripped = seed;

            break;
        };
    }

    const seed = tripped orelse return error.TestUnexpectedResult;
    const repeated = canary_run(&.{ .events_max = 4096, .seed = seed });

    try std.testing.expectError(error.CanaryTripped, repeated);
}

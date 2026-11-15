const std = @import("std");

const assert = std.debug.assert;

const Artifact = struct {
    name: []const u8,
    root: []const u8,
};

const Context = struct {
    bounded: *std.Build.Module,
    builder: *std.Build,
    filters: []const []const u8,
    json: *std.Build.Module,
    module: *std.Build.Module,
    optimize: std.lang.Optimize,
    steps: Steps,
    target: std.Build.ResolvedTarget,
};

const Steps = struct {
    check: *std.Build.Step,
    continuous_integration: *std.Build.Step,
    example: *std.Build.Step,
    fuzz: *std.Build.Step,
    fuzz_build: *std.Build.Step,
    fuzz_smoke: *std.Build.Step,
    generate: *std.Build.Step,
    generate_check: *std.Build.Step,
    run: *std.Build.Step,
    test_all: *std.Build.Step,
    test_format: *std.Build.Step,
    test_unit: *std.Build.Step,
};

const artifact_cli: Artifact = .{ .name = "fit", .root = "src/main.zig" };
const artifact_example: Artifact = .{ .name = "decode", .root = "examples/decode.zig" };
const artifact_fuzz: Artifact = .{ .name = "fuzz", .root = "src/fuzz_tests.zig" };
const artifact_generator: Artifact = .{ .name = "generator", .root = "src/generator/main.zig" };
const format_paths = [_][]const u8{ "build.zig", "examples", "src" };
const generated_messages = "src/profile/messages.zig";
const generated_types = "src/profile/types.zig";
const module_root = "src/fit.zig";
const specification = "spec/Profile.xlsx";
const unit_tests_root = "src/unit_tests.zig";

const supported_targets = [_]std.Target.Query{
    .{ .cpu_arch = .x86_64, .os_tag = .linux },
    .{ .cpu_arch = .x86_64, .os_tag = .windows },
};

comptime {
    assert(format_paths.len == 3);
    assert(supported_targets.len == 2);
    assert(std.mem.endsWith(u8, specification, ".xlsx"));
}

pub fn build(builder: *std.Build) void {
    assert(builder.graph.host.result.ptrBitWidth() == 64);

    const filters = builder.option(
        []const []const u8,
        "test-filter",
        "Skip tests that do not match any filter",
    ) orelse &.{};

    const context = Context{
        .bounded = builder.dependency("bounded", .{}).module("bounded"),
        .builder = builder,
        .filters = filters,
        .json = builder.dependency("json", .{}).module("json"),
        .module = builder.addModule("fit", .{ .root_source_file = builder.path(module_root) }),
        .optimize = builder.standardOptimizeOption(.{ .preferred_optimize_mode = null }),
        .steps = steps_declare(builder),
        .target = builder.standardTargetOptions(.{ .whitelist = null, .default_target = .{} }),
    };

    add_check(&context);
    add_cli(&context);
    add_example(&context);
    add_format(&context);
    add_fuzz(&context);
    add_generate(&context);
    add_unit_tests(&context);

    context.steps.continuous_integration.dependOn(context.steps.check);
    context.steps.continuous_integration.dependOn(context.steps.example);
    context.steps.continuous_integration.dependOn(context.steps.fuzz_smoke);
    context.steps.continuous_integration.dependOn(context.steps.generate_check);
    context.steps.continuous_integration.dependOn(context.steps.test_all);
}

fn steps_declare(builder: *std.Build) Steps {
    assert(builder.graph.host.result.ptrBitWidth() == 64);

    const result = Steps{
        .check = builder.step("check", "Compile every artifact for Linux and Windows"),
        .continuous_integration = builder.step("ci", "Run every check, test, and fuzz smoke"),
        .example = builder.step("example", "Build and run the example against the module"),
        .fuzz = builder.step("fuzz", "Run a fuzzer: zig build fuzz -- <fuzzer> [seed] [events]"),
        .fuzz_build = builder.step("fuzz:build", "Compile the fuzzers without running them"),
        .fuzz_smoke = builder.step("fuzz:smoke", "Run every fuzzer briefly with a fixed seed"),
        .generate = builder.step("generate", "Generate the profile tables from the FIT SDK"),
        .generate_check = builder.step("generate:check", "Check the profile tables are current"),
        .run = builder.step("run", "Dump a FIT file: zig build run -- <file.fit> [mode]"),
        .test_all = builder.step("test", "Run every test suite and the format check"),
        .test_format = builder.step("test:fmt", "Check that every source file is formatted"),
        .test_unit = builder.step("test:unit", "Run the unit tests and the tidy check"),
    };

    assert(result.check != result.test_all);
    assert(result.generate != result.generate_check);

    return result;
}

fn executable(
    context: *const Context,
    target: std.Build.ResolvedTarget,
    artifact: Artifact,
) *std.Build.Step.Compile {
    assert(target.result.ptrBitWidth() == 64);
    assert(artifact.name.len > 0);
    assert(std.mem.endsWith(u8, artifact.root, ".zig"));

    return context.builder.addExecutable(.{
        .name = artifact.name,
        .root_module = context.builder.createModule(.{
            .root_source_file = context.builder.path(artifact.root),
            .target = target,
            .optimize = context.optimize,
            .omit_frame_pointer = false,
            .imports = &.{
                .{ .name = "bounded", .module = context.bounded },
                .{ .name = "json", .module = context.json },
            },
        }),
    });
}

fn example(context: *const Context, target: std.Build.ResolvedTarget) *std.Build.Step.Compile {
    assert(target.result.ptrBitWidth() == 64);
    assert(std.mem.startsWith(u8, artifact_example.root, "examples/"));

    return context.builder.addExecutable(.{
        .name = artifact_example.name,
        .root_module = context.builder.createModule(.{
            .root_source_file = context.builder.path(artifact_example.root),
            .target = target,
            .optimize = context.optimize,
            .imports = &.{.{ .name = "fit", .module = context.module }},
        }),
    });
}

fn add_check(context: *const Context) void {
    assert(supported_targets.len > 0);
    assert(context.steps.check != context.steps.test_all);

    const artifacts = [_]Artifact{ artifact_cli, artifact_fuzz, artifact_generator };

    for (supported_targets) |query| {
        const resolved = context.builder.resolveTargetQuery(query);

        for (artifacts) |artifact| {
            const compiled = executable(context, resolved, artifact);

            context.steps.check.dependOn(&compiled.step);
        }

        context.steps.check.dependOn(&example(context, resolved).step);
        context.steps.check.dependOn(&unit_tests(context, resolved).step);
    }
}

fn add_cli(context: *const Context) void {
    assert(context.steps.run != context.steps.check);
    assert(artifact_cli.root.len > 0);

    const cli = executable(context, context.target, artifact_cli);
    const run = context.builder.addRunArtifact(cli);

    const install = context.builder.addInstallArtifact(cli, .{
        .dest_dir = .default,
        .pdb_dir = .default,
        .compiler_rt_dyn_lib_dir = .default,
        .h_dir = .default,
        .implib_dir = .default,
        .dylib_symlinks = null,
        .dest_sub_path = null,
    });

    run.addPassthruArgs();

    context.builder.getInstallStep().dependOn(&install.step);
    context.steps.run.dependOn(&run.step);
}

fn add_example(context: *const Context) void {
    assert(context.steps.example != context.steps.check);
    assert(artifact_example.root.len > 0);

    const run = context.builder.addRunArtifact(example(context, context.target));

    context.steps.example.dependOn(&run.step);
}

fn add_format(context: *const Context) void {
    assert(format_paths.len > 0);
    assert(context.steps.test_format != context.steps.test_all);

    const format = context.builder.addFmt(.{
        .paths = context.builder.pathList(&format_paths),
        .check = true,
    });

    context.steps.test_format.dependOn(&format.step);
    context.steps.test_all.dependOn(&format.step);
}

fn add_fuzz(context: *const Context) void {
    assert(context.steps.fuzz != context.steps.fuzz_smoke);
    assert(artifact_fuzz.root.len > 0);

    const fuzz = executable(context, context.target, artifact_fuzz);
    const fuzz_run = context.builder.addRunArtifact(fuzz);
    const fuzz_smoke = context.builder.addRunArtifact(fuzz);

    const fuzz_install = context.builder.addInstallArtifact(fuzz, .{
        .dest_dir = .default,
        .pdb_dir = .default,
        .compiler_rt_dyn_lib_dir = .default,
        .h_dir = .default,
        .implib_dir = .default,
        .dylib_symlinks = null,
        .dest_sub_path = null,
    });

    fuzz_run.addPassthruArgs();
    fuzz_smoke.addArg("smoke");

    context.steps.fuzz.dependOn(&fuzz_run.step);
    context.steps.fuzz_build.dependOn(&fuzz_install.step);
    context.steps.fuzz_smoke.dependOn(&fuzz_smoke.step);
}

fn add_generate(context: *const Context) void {
    assert(context.steps.generate != context.steps.generate_check);
    assert(specification.len > 0);

    const generator = executable(context, context.builder.graph.host, artifact_generator);

    const modes = [_]struct { name: []const u8, step: *std.Build.Step }{
        .{ .name = "write", .step = context.steps.generate },
        .{ .name = "check", .step = context.steps.generate_check },
    };

    for (modes) |mode| {
        const run = context.builder.addRunArtifact(generator);

        run.addArgs(&.{ mode.name, specification, generated_types, generated_messages });
        run.setCwd(context.builder.path("."));
        run.has_side_effects = true;

        mode.step.dependOn(&run.step);
    }
}

fn unit_tests(context: *const Context, target: std.Build.ResolvedTarget) *std.Build.Step.Compile {
    assert(target.result.ptrBitWidth() == 64);
    assert(context.filters.len < 64);
    assert(unit_tests_root.len > 0);

    return context.builder.addTest(.{
        .name = "unit_tests",
        .root_module = context.builder.createModule(.{
            .root_source_file = context.builder.path(unit_tests_root),
            .target = target,
            .optimize = context.optimize,
            .imports = &.{
                .{ .name = "bounded", .module = context.bounded },
                .{ .name = "json", .module = context.json },
            },
        }),
        .filters = context.filters,
    });
}

fn add_unit_tests(context: *const Context) void {
    assert(context.steps.test_unit != context.steps.test_all);
    assert(unit_tests_root.len > 0);

    const suite = unit_tests(context, context.target);
    const run = context.builder.addRunArtifact(suite);

    run.setCwd(context.builder.path("."));
    run.has_side_effects = true;

    context.steps.test_unit.dependOn(&run.step);
    context.steps.test_all.dependOn(&run.step);
}

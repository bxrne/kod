const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const enable_instrumentation = b.option(
        bool,
        "enable-instrumentation",
        "Enable runtime instrumentation output",
    ) orelse false;

    const runtime_options = b.addOptions();
    runtime_options.addOption(bool, "enable_instrumentation", enable_instrumentation);

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/lib/mod.zig"),
        .target = target,
    });

    const editor_mod = b.createModule(.{
        .root_source_file = b.path("src/editor/mod.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "lib", .module = lib_mod },
        },
    });

    const kod_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "lib", .module = lib_mod },
            .{ .name = "editor", .module = editor_mod },
        },
    });

    const exe_root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "kod", .module = kod_mod },
        },
    });
    exe_root_module.addOptions("build_options", runtime_options);

    const exe = b.addExecutable(.{
        .name = "kod",
        .root_module = exe_root_module,
    });

    const bench_root_module = b.createModule(.{
        .root_source_file = b.path("src/bench_main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "kod", .module = kod_mod },
        },
    });
    bench_root_module.addOptions("build_options", runtime_options);

    const bench_exe = b.addExecutable(.{
        .name = "kod-bench",
        .root_module = bench_root_module,
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    const bench_step = b.step("bench", "Run editor microbenchmarks");
    const bench_cmd = b.addRunArtifact(bench_exe);
    bench_step.dependOn(&bench_cmd.step);

    if (b.args) |args| {
        run_cmd.addArgs(args);
        bench_cmd.addArgs(args);
    }

    const test_step = b.step("test", "Run tests");

    const lib_tests = b.addTest(.{ .root_module = lib_mod });
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);

    const editor_tests = b.addTest(.{ .root_module = editor_mod });
    test_step.dependOn(&b.addRunArtifact(editor_tests).step);

    const kod_tests = b.addTest(.{ .root_module = kod_mod });
    test_step.dependOn(&b.addRunArtifact(kod_tests).step);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
}

const std = @import("std");

/// Single source of truth: `build.zig.zon` `.version`. Parsed at
/// comptime from the embedded file, so the welcome text, the `:help`
/// listing, and `--version` can never drift from the package that
/// commitizen bumps. A missing, unquoted, or empty field fails the
/// build here instead of printing an empty version later.
fn loadVersion() []const u8 {
    const text = @embedFile("build.zig.zon");
    const key = ".version";
    const at = comptime std.mem.indexOf(u8, text, key) orelse
        @compileError("build.zig.zon has no .version field");
    const open = comptime std.mem.findScalarPos(u8, text, at + key.len, '"') orelse
        @compileError("build.zig.zon .version is not a quoted string");
    const close = comptime std.mem.findScalarPos(u8, text, open + 1, '"') orelse
        @compileError("build.zig.zon .version string is unterminated");
    const v = comptime text[open + 1 .. close];
    if (comptime v.len == 0) @compileError("build.zig.zon .version is empty");
    return v;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const version = b.option(
        []const u8,
        "version",
        "override the version from build.zig.zon",
    ) orelse loadVersion();

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("lib/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "lib", .module = lib_mod },
        },
    });
    const version_opts = b.addOptions();
    version_opts.addOption([]const u8, "version", version);
    exe_mod.addOptions("config", version_opts);

    const exe = b.addExecutable(.{
        .name = "kod",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const install_step = b.step("binstall", "Install kod to ~/.local/bin");
    const home = b.graph.environ_map.get("HOME") orelse @panic("HOME environment variable not set");
    const local_bin = b.pathJoin(&.{ home, ".local", "bin" });
    const install_dir = b.addSystemCommand(&.{ "mkdir", "-p", local_bin });
    install_step.dependOn(&install_dir.step);
    const install_copy = b.addSystemCommand(&.{ "cp", "-f" });
    install_copy.addArtifactArg(exe);
    install_copy.addArg(b.pathJoin(&.{ local_bin, "kod" }));
    install_copy.step.dependOn(&install_dir.step);
    install_step.dependOn(&install_copy.step);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = exe_mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = lib_mod })).step);
}

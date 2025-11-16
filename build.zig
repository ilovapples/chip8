const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lite_argparse_mod = b.createModule(.{
        .root_source_file = b.path("../../c/arg_parse/arg_parse.zig"),
        .target = target,
        .optimize = optimize,
    });

    const chip8_mod = b.createModule(.{
        .root_source_file = b.path("chip8.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "chip8",
        .root_module = chip8_mod,
    });
    const chip8_asm_mod = b.createModule(.{
        .root_source_file = b.path("asm.zig"),
        .target = target,
        .optimize = optimize,
    });
    const as8_exe = b.addExecutable(.{
        .name = "as8",
        .root_module = chip8_asm_mod,
    });

    const mibu_dep = b.dependency("mibu", .{});
    chip8_mod.addImport("mibu", mibu_dep.module("mibu"));
    chip8_mod.addImport("lite_argparse", lite_argparse_mod);
    chip8_asm_mod.addImport("mibu", mibu_dep.module("mibu"));
    chip8_asm_mod.addImport("lite_argparse", lite_argparse_mod);

    b.installArtifact(exe);
    b.installArtifact(as8_exe);

    const run_step = b.step("run", "run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "run unit tests");
    const unit_tests = b.addTest(.{
        .root_module = chip8_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);
}

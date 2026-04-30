const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const chip8_mod = b.createModule(.{
        .root_source_file = b.path("chip8_emu.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "chip8_emu",
        .root_module = chip8_mod,
    });
    const chip8_asm_mod = b.createModule(.{
        .root_source_file = b.path("assembler.zig"),
        .target = target,
        .optimize = optimize,
    });
    const as8_exe = b.addExecutable(.{
        .name = "as8",
        .root_module = chip8_asm_mod,
    });

    const mibu_dep = b.dependency("mibu", .{ .optimize = optimize, .target = target }).module("mibu");
    const jitargs_mod = b.dependency("jitargs", .{ .optimize = optimize, .target = target }).module("jitargs");
    chip8_mod.addImport("mibu", mibu_dep);
    chip8_mod.addImport("jitargs", jitargs_mod);
    chip8_asm_mod.addImport("mibu", mibu_dep);
    chip8_asm_mod.addImport("jitargs", jitargs_mod);

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

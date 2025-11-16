const std = @import("std");
const chip8 = @import("chip8.zig");

pub fn write_endian(endian: std.builtin.Endian) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    var out_buffer: [512]u8 = undefined;
    var out_file_writer = std.fs.File.stdout().writer(&out_buffer);
    const outw = &out_file_writer.interface;
    var err_buffer: [512]u8 = undefined;
    var err_file_writer = std.fs.File.stderr().writer(&err_buffer);
    const errw = &err_file_writer.interface;

    if (args.len < 2) {
        std.log.err("not enough args", .{});
        std.process.exit(1);
    }

    const arg_1 = args[1];
    const IntType = u16;
    const instr: chip8.Chip8Emu.RomInstruction = @bitCast(try std.fmt.parseInt(u16, arg_1, 16));

    try outw.writeInt(IntType, @bitCast(instr), endian);
    try outw.flush();

    try errw.print("category: {t}\n", .{instr.category});
    try errw.print("operands: {x:0>12}\n", .{@as(u12, @bitCast(instr.operands))});
    try errw.print("nibbles = <{x}, {x}, {x}>\n", .{instr.operands.nybbles.@"1", instr.operands.nybbles.@"2", instr.operands.nybbles.@"3"});

    try errw.flush();
}


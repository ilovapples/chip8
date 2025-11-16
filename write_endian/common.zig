const std = @import("std");
const chip8 = @import("chip8.zig");

pub const my_instr: chip8.Chip8Emu.RomInstruction = @bitCast(@as(u16, 0x6139 // 39 61
        ));
// .{
//     .category = .mov_imm,
//     .operands = .{ .reg_imm = .{
//         .reg = 1,
//         .imm = 0x39,
//     }},
// };

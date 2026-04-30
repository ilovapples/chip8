const std = @import("std");
const testing = std.testing;

pub const Addr = u12;

pub const Registers = struct {
    /// general-purpose registers V0-VF
    v: [16]u8,
    /// index register. stores memory addresses
    i: Addr,
    /// program counter. points to next instruction in memory.
    pc: Addr = Ram.offsets.program_data,
    /// stack pointer.
    sp: Sp,
    /// value that decrements at 60hz when non-zero ('delay timer')
    dt: u8,
    /// value that decrements at 60hz with a beep when non-zero ('sound timer')
    st: u8,

    pub const Sp = u4;
};

/// 0x000-0x200 = reserved for interpreter and font sprites.
/// 0x200-0x1000 = available for program code and data (program starts at 0x200)
/// 4096 byte memory, blocked into chunks for convenience.
/// can be `@bitCast`ed into `[4096]u8`
pub const Ram = extern struct {
    unused0: [0x050]u8 = @splat(0),
    font_block: [0x050]u8 = @bitCast(chars_font),
    unused1: [0x160]u8 = @splat(0),
    program_data: [0xe00]u8 = @splat(0),

    pub const offsets = struct {
        pub const unused0: Addr = 0x000;
        pub const font_block: Addr = 0x050;
        pub const unused1: Addr = 0x0100;
        pub const program_data: Addr = 0x200;
    };

    pub fn full(ram: *Ram) *[0x1000]u8 {
        return @ptrCast(ram);
    }
    pub fn fullConst(ram: *const Ram) *const [0x1000]u8 {
        return @ptrCast(ram);
    }
};
test Ram {
    try testing.expectEqual(0x1000, @sizeOf(Ram));
}

/// stored in `ram[0x050..0x0a0]`
/// each char is 4x5 pixels, stored as 5*8 bits or [5]u8
/// each row of a sprite is 8 bits wide, so just ignore upper 4 bits for this
pub const CharFont = [5]u8;
pub const chars_font = [16]CharFont{
    // '0'
    .{
        0b0100_0000,
        0b1010_0000,
        0b1010_0000,
        0b1010_0000,
        0b0100_0000,
    },
    // '1'
    .{
        0b0100_0000,
        0b1100_0000,
        0b0100_0000,
        0b0100_0000,
        0b1110_0000,
    },
    // '2'
    .{
        0b1100_0000,
        0b0010_0000,
        0b0100_0000,
        0b1000_0000,
        0b1110_0000,
    },
    // '3'
    .{
        0b1100_0000,
        0b0010_0000,
        0b0100_0000,
        0b0010_0000,
        0b1100_0000,
    },
    // '4'
    .{
        0b0010_0000,
        0b0110_0000,
        0b1010_0000,
        0b1110_0000,
        0b0010_0000,
    },
    // '5'
    .{
        0b1110_0000,
        0b1000_0000,
        0b1110_0000,
        0b0010_0000,
        0b1110_0000,
    },
    // '6'
    .{
        0b1110_0000,
        0b1000_0000,
        0b1110_0000,
        0b1010_0000,
        0b1110_0000,
    },
    // '7'
    .{
        0b1110_0000,
        0b0010_0000,
        0b0100_0000,
        0b0100_0000,
        0b0100_0000,
    },
    // '8'
    .{
        0b1110_0000,
        0b1010_0000,
        0b1110_0000,
        0b1010_0000,
        0b1110_0000,
    },
    // '9'
    .{
        0b1110_0000,
        0b1010_0000,
        0b1110_0000,
        0b0010_0000,
        0b1110_0000,
    },
    // 'A'
    .{
        0b0110_0000,
        0b1010_0000,
        0b1110_0000,
        0b1010_0000,
        0b1010_0000,
    },
    // 'B'
    .{
        0b1100_0000,
        0b1010_0000,
        0b1100_0000,
        0b1010_0000,
        0b1100_0000,
    },
    // 'C'
    .{
        0b0110_0000,
        0b1000_0000,
        0b1000_0000,
        0b1000_0000,
        0b0110_0000,
    },
    // 'D'
    .{
        0b1100_0000,
        0b1010_0000,
        0b1010_0000,
        0b1010_0000,
        0b1100_0000,
    },
    // 'E'
    .{
        0b1110_0000,
        0b1000_0000,
        0b1100_0000,
        0b1000_0000,
        0b1110_0000,
    },
    // 'F'
    .{
        0b1110_0000,
        0b1000_0000,
        0b1100_0000,
        0b1000_0000,
        0b1000_0000,
    },
};
test chars_font {
    try testing.expectEqual(0x50, @sizeOf(@TypeOf(chars_font)));
}

pub const Vram = struct {
    raw: [32]u64,

    pub const DisplayBuffer = *const [32]u64;

    pub fn draw_xy(vram: *Vram, reg: *Registers, sprite_bytes: []const u8, x: u8, y: u8) void {
        // this code is pain
        const wrapped_x: u6 = @intCast(x & 63);
        const wrapped_y: u5 = @intCast(y & 31);

        reg.v[0xf] = 0;

        for (sprite_bytes, 0..) |spr_row, row_i| {
            const cur_y: u5 = @intCast((wrapped_y + row_i) % 32);

            if (wrapped_x <= 56) { // no horizontal wrapping
                const shifted_sprite_row = @as(u64, spr_row) << (56 - wrapped_x);

                if (vram.raw[cur_y] & shifted_sprite_row != 0) reg.v[0xf] = 1;

                vram.raw[cur_y] ^= shifted_sprite_row;
            } else { // at least 1 pixel horizontally wrapped
                // always >0
                const wrapped_count: u3 = @intCast(wrapped_x - 56);
                const not_wrapped_row = spr_row >> wrapped_count;
                const wrapped_row = spr_row & (@as(u8, 1) << wrapped_count) - 1;
                const new_row: u64 = @as(u64, not_wrapped_row) | @as(u64, wrapped_row) << @intCast(64 - @as(u8, wrapped_count));

                if (vram.raw[cur_y] & new_row != 0) reg.v[0xf] = 1;

                vram.raw[cur_y] ^= new_row;
            }
        }
    }
};

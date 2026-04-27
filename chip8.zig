const std = @import("std");
const atomic = std.atomic;
const builtin = @import("builtin");
const posix = std.posix;
const testing = std.testing;
const assert = std.debug.assert;

const mibu = @import("mibu");
const ArgParser = @import("lite_argparse").ArgParser;
const rawmode_term = @import("term.zig");

const as8 = @import("asm.zig");

const error_msgs = @import("error_msgs.zig");

const interfaces = @import("interfaces.zig");
const Chip8TermIO = interfaces.Chip8TermIO;

pub const Chip8Emu = struct {
    ram: Ram,

    /// registers
    reg: Registers,

    /// stack. reg.sp points to the top element (current stack frame)
    stack: [16]Registers.pc_t,

    /// video buffer (64x32 monochrome pixels)
    video: Vram,

    /// 0x000 - 0x1ff = reserved for interpreter and font sprites.
    /// 0x200 - 0xfff = available for program code and data (program typically starts at 0x200)
    /// 4096 byte memory, blocked into chunks for convenience.
    /// can be `@bitCast`ed into `[4096]u8`
    pub const Ram = struct {
        /// `ram[0x000..0x050]`
        unused0: [0x050]u8,
        /// `ram[0x050..0x0a0]`
        font_block: [0x050]u8 = @bitCast(chars_font),
        /// `ram[0x0a0..0x200]`
        unused1: [0x160]u8,
        /// `ram[0x200..]`
        program_data: [0xe00]u8,

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

        // namespace? like a C enum because @intFromEnum is too long
        pub const Offset = struct {
            const unused_block0 = 0x000;
            const font_block = 0x050;
            const unused_block1 = 0x0a0;
            const program_data = 0x200;
            const last = 0x1000;
        };
    };

    pub const Registers = struct {
        /// general-purpose registers V0-VF
        v: [16]u8,
        /// index register. stores memory addresses
        i: chip8_usize,
        /// program counter. points to next instruction in memory. valid range = `[0x000, 0xfff]`
        pc: pc_t = undefined,
        /// stack pointer. valid range = `[0x0, 0xf]`
        sp: sp_t,
        /// timer that decrements at 60Hz when non-zero ('delay timer')
        dt: u8,
        /// timer that decrements at 60Hz with a beep when non-zero ('sound timer')
        st: u8,

        // for now probably fine to use u12 and u4, but might change to u16 and u8 later.
        pub const pc_t = chip8_usize;
        pub const sp_t = u4;
    };

    pub const Vram = struct {
        raw: [32]u64,

        pub const DisplayBuffer = *const [32]u64;

        /// xor's vram with sprite, places into vram.
        pub fn draw_xor(vram: *Vram, sprite: DisplayBuffer) void {
            const AlignedU2048Ptr = *align(@alignOf(@TypeOf(vram.raw))) u2048;
            const ConstAlignedU2048Ptr = *align(@alignOf(@TypeOf(vram.raw))) const u2048;
            @as(AlignedU2048Ptr, @ptrCast(&vram.raw)).* ^= @as(ConstAlignedU2048Ptr, @ptrCast(sprite)).*;
        }
        pub fn draw_xy(vram: *Vram, emu: *Chip8Emu, sprite_bytes: []const u8, x: u8, y: u8) void {
            // this code is pain
            const wrapped_x: u6 = @intCast(x & 63);
            const wrapped_y: u5 = @intCast(y & 31);

            emu.reg.v[0xf] = 0;

            for (sprite_bytes, 0..) |spr_row, row_i| {
                const cur_y: u5 = @intCast((wrapped_y + row_i) % 32);

                if (wrapped_x <= 56) { // no horizontal wrapping
                    const shifted_sprite_row = @as(u64, spr_row) << (56 - wrapped_x);

                    if (vram.raw[cur_y] & shifted_sprite_row != 0) emu.reg.v[0xf] = 1;

                    vram.raw[cur_y] ^= shifted_sprite_row;
                } else { // at least 1 pixel horizontally wrapped
                    // always >0
                    const wrapped_count: u3 = @intCast(wrapped_x - 56);
                    const not_wrapped_row = spr_row >> wrapped_count;
                    const wrapped_row = spr_row & (@as(u8, 1) << wrapped_count) - 1;
                    const new_row: u64 = @as(u64, not_wrapped_row) | @as(u64, wrapped_row) << @intCast(64 - @as(u8, wrapped_count));

                    if (vram.raw[cur_y] & new_row != 0) emu.reg.v[0xf] = 1;

                    vram.raw[cur_y] ^= new_row;
                }
            }
        }
    };
    test Vram {
        var vram = std.mem.zeroes(Vram);
        const sprite: Vram.DisplayBuffer = &[_]u64{0x0a} ** 32;
        vram.draw_xor(sprite);
        try testing.expect(std.mem.allEqual(u64, &vram.raw, 0x0a));
        vram.draw_xor(sprite);
        try testing.expect(std.mem.allEqual(u64, &vram.raw, 0x00));
    }

    pub const RomInstruction = packed struct(u16) {
        // stored in ascending bit significance,
        // so operands is stored in the least significant 3 nybbles, category in the most significant one.

        operands: Operands,
        category: InstructionCategory,

        /// http://devernay.free.fr/hacks/chip8/chip8def.htm
        pub const InstructionCategory = enum(u4) {
            /// 0xxx: super things, ret, cls
            special = 0x0,
            /// 1XXX: branch w/o link to instruction XXX
            jmp = 0x1,
            /// 2XXX: branch w/ link to instruction XXX
            jsl = 0x2,
            /// 3RXX: skip next instruction if VR == XX
            skeq = 0x3,
            /// 4RXX: skip next instruction if VR != XX
            skne = 0x4,
            /// 5RY0: skip next instruction if VR == VY
            skeq_reg = 0x5,
            /// 6RXX: move immediate XX into VR
            mov_imm = 0x6,
            /// 7RXX: add immediate to VR, no carry generated
            add_imm = 0x7,
            /// 8RYx: perform an operation on VR and VY, put result in VR
            mov_reg = 0x8,
            /// 9RY0: skip next instrution if VR != VY
            skne_reg = 0x9,
            /// AXXX: load constant XXX into index register
            mvi = 0xa,
            /// BXXX: jump to address XXX + V0
            jmi = 0xb,
            /// CRXX: load random number <= XX into VR
            rand = 0xc,
            /// DRYs: draw sprite at screen location VR, VY, with height s,
            /// DRY0: (xsprite) draw extended sprite at location VR, VY (always 16x16, SUPERCHIP only)
            sprite = 0xd,
            /// EK9E: skip if key K pressed (skpr)
            /// EKA1: skip if key K not pressed (skup)
            skpr_skup = 0xe,
            /// Fxxx: load fonts, play sounds, do delays, input
            extra_media = 0xf,
        };

        pub const Operands = packed union {
            /// xXXX
            addr: chip8_usize,
            /// xRXX
            reg_imm: packed struct(u12) {
                imm: u8,
                regR: u4,
            },
            /// xXXY
            byte_nybble: packed struct(u12) {
                nybble: u4,
                byte: u8,
            },
            /// xXYY
            nybble_byte: packed struct(u12) {
                byte: u8,
                nybble: u4,
            },
            /// xRY0
            reg_reg_unused: packed struct(u12) {
                unused: u4,
                regY: u4,
                regR: u4,
            },
            /// 8RYx
            reg_reg_op: packed struct(u12) {
                op: u4,
                regY: u4,
                regR: u4,
            },
            /// DRYn
            reg_reg_imm: packed struct(u12) {
                imm: u4,
                regY: u4,
                regR: u4,
            },
            /// x0XX
            unused_byte: packed struct(u12) {
                byte: u8,
                unused: u4,
            },
            /// x0XY
            unused_nybble_nybble: packed struct(u12) {
                nyb2: u4,
                nyb1: u4,
                unused: u4,
            },
        };
    };
    test RomInstruction {
        _ = RomInstruction;
    }

    pub const chip8_usize = u12;

    /// return number of instructions loaded
    pub fn loadRom(emu: *Chip8Emu, rom_reader: *std.Io.Reader) !usize {
        const buf: *[0xe00]u8 = &emu.ram.program_data;

        // stream doesn't want to work here so i have to do a manual loop
        // var data_off: usize = 0;
        // while (data_off < buf.len) : (data_off += 1) {
        //     buf[data_off] = rom_reader.takeByte() catch break;
        // }
        // return data_off;
        _ = try rom_reader.readSliceShort(buf);
        @panic("hi");
    }

    inline fn getRamArray(emu: *Chip8Emu) *[4096]u8 {
        return @ptrCast(&emu.ram);
    }

    fn toBigEndian(v: anytype) @TypeOf(v) {
        return if (builtin.cpu.arch.endian() == .big) v else @byteSwap(v);
    }

    /// emulate the CHIP8 instruction set.
    ///
    /// returns the value in V0 register at termination.
    ///
    /// you probably want to call emu.loadRom first, to load a ROM into memory.
    pub fn emulateProgramData(emu: *Chip8Emu, io_interface: IoInterface) !u8 {
        // initialize program counter (link register)
        emu.reg.pc = Ram.Offset.program_data;
        const ram_arr = emu.getRamArray();

        var xoshiro = std.Random.Xoshiro256.init(@intCast(@intFromPtr(emu)));
        const rand = xoshiro.random();

        var sixty_hz_flag: atomic.Value(bool) = .init(false);
        var threads_should_terminate: atomic.Value(bool) = .init(false);
        defer threads_should_terminate.store(true, .release);
        _ = try std.Thread.spawn(.{}, sixtyHzThread, .{
            &sixty_hz_flag,
            &threads_should_terminate,
        });
        // var should_stop_executing: atomic.Value(bool) = .init(false);
        // _ = try std.Thread.spawn(.{}, checkForTerminateKey, .{
        //     &should_stop_executing,
        //     &threads_should_terminate,
        //     io_interface,
        // });

        var cycle: u64 = 0;
        while (true) : (cycle += 1) {
            const cur_instr: RomInstruction = @bitCast(toBigEndian(std.mem.bytesToValue(u16, ram_arr[emu.reg.pc..][0..@sizeOf(RomInstruction)])));
            const middle_byte = cur_instr.operands.byte_nybble.byte;
            const nybble_byte = cur_instr.operands.nybble_byte;
            const last_nybble = cur_instr.operands.unused_nybble_nybble.nyb2;

            var video_changed = false;

            //std.debug.print("${x:0>3}: {x:0>4}\n", .{emu.reg.pc, @as(u16, @bitCast(cur_instr))});

            switch (cur_instr.category) {
                // 00xx
                .special => switch (middle_byte) {
                    // 00AR: debug print contents of VR as character (custom)
                    0x0A => std.debug.print("{c}\n", .{emu.reg.v[last_nybble]}),
                    // 00BR: debug print contents of VR in hex (custom)
                    0x0B => std.debug.print("{x:0>2}\n", .{emu.reg.v[last_nybble]}),
                    // 01BR: debug print contents of VR in decimal (custom)
                    0x1B => std.debug.print("{d}\n", .{emu.reg.v[last_nybble]}),
                    0x0C => @panic("super instruction; not implemented"),
                    // 00Ex
                    0x0E => switch (last_nybble) {
                        0x0 => {
                            @memset(&emu.video.raw, 0);
                            video_changed = true;
                        },
                        0xE => { // ret
                            if (builtin.mode == .Debug and emu.reg.sp == 0x0) return error.StackOverflow;
                            emu.reg.sp -= 1;
                            emu.reg.pc = emu.stack[emu.reg.sp];
                        },
                        else => unreachable,
                    },
                    0x0F => switch (last_nybble) {
                        0xD => return emu.reg.v[0],
                        else => @panic("super instruction; not implemented"),
                    },
                    else => unreachable,
                },
                .jmp => {
                    emu.reg.pc = cur_instr.operands.addr;
                    continue;
                },
                .jsl => {
                    emu.stack[emu.reg.sp] = emu.reg.pc;
                    if (builtin.mode == .Debug and emu.reg.sp +% 1 == 0) return error.StackOverflow;
                    emu.reg.sp += 1;
                    emu.reg.pc = cur_instr.operands.addr;
                    continue;
                },
                .skeq => {
                    const reg_imm = cur_instr.operands.reg_imm;
                    emu.reg.pc += @sizeOf(RomInstruction) *
                        @as(u12, @intCast(@intFromBool(emu.reg.v[reg_imm.regR] == reg_imm.imm)));
                },
                .skne => {
                    const reg_imm = cur_instr.operands.reg_imm;
                    emu.reg.pc += @sizeOf(RomInstruction) *
                        @as(u12, @intCast(@intFromBool(emu.reg.v[reg_imm.regR] != reg_imm.imm)));
                },
                .skeq_reg => {
                    const reg_reg = cur_instr.operands.reg_reg_unused;
                    emu.reg.pc += @sizeOf(RomInstruction) *
                        @as(u12, @intCast(@intFromBool(emu.reg.v[reg_reg.regR] == emu.reg.v[reg_reg.regY])));
                },
                .mov_imm => {
                    const reg_imm = cur_instr.operands.reg_imm;
                    emu.reg.v[reg_imm.regR] = reg_imm.imm;
                },
                .add_imm => {
                    const reg_imm = cur_instr.operands.reg_imm;
                    emu.reg.v[reg_imm.regR] +%= reg_imm.imm;
                },
                .mov_reg => {
                    const reg_reg_op = cur_instr.operands.reg_reg_op;
                    switch (reg_reg_op.op) {
                        0x0 => emu.reg.v[reg_reg_op.regR] = emu.reg.v[reg_reg_op.regY],
                        0x1 => emu.reg.v[reg_reg_op.regR] |= emu.reg.v[reg_reg_op.regY],
                        0x2 => emu.reg.v[reg_reg_op.regR] &= emu.reg.v[reg_reg_op.regY],
                        0x3 => emu.reg.v[reg_reg_op.regR] ^= emu.reg.v[reg_reg_op.regY],
                        0x4 => { // add with overflow
                            emu.reg.v[reg_reg_op.regR], emu.reg.v[0xf] =
                                @addWithOverflow(emu.reg.v[reg_reg_op.regR], emu.reg.v[reg_reg_op.regY]);
                        },
                        0x5 => { // sub with overflow
                            const tuple = @subWithOverflow(emu.reg.v[reg_reg_op.regR], emu.reg.v[reg_reg_op.regY]);
                            emu.reg.v[reg_reg_op.regR] = tuple.@"0";
                            emu.reg.v[0xf] = 1 - tuple.@"1";
                        },
                        0x6 => { // shr, save removed bit in vf (no builtin, so we're doing this)
                            const flag_val = emu.reg.v[reg_reg_op.regR] & 0x1;
                            emu.reg.v[reg_reg_op.regR] >>= 1;
                            emu.reg.v[0xf] = flag_val;
                        },
                        0x7 => { // rsb -> vr = vy - vr
                            const tuple = @subWithOverflow(emu.reg.v[reg_reg_op.regY], emu.reg.v[reg_reg_op.regR]);
                            emu.reg.v[reg_reg_op.regR] = tuple.@"0";
                            emu.reg.v[0xf] = 1 - tuple.@"1";
                        },
                        0xe => {
                            // shl, save removd bit in vf
                            // (second nybble can be 0 for shl by 1, or any other number to shift by that amount)
                            emu.reg.v[reg_reg_op.regR], emu.reg.v[0xf] =
                                @shlWithOverflow(emu.reg.v[reg_reg_op.regR], 1);
                        },
                        else => unreachable,
                    }
                },
                .skne_reg => {
                    const reg_reg = cur_instr.operands.reg_reg_unused;
                    emu.reg.pc += @sizeOf(RomInstruction) *
                        @as(u12, @intCast(@intFromBool(emu.reg.v[reg_reg.regR] != emu.reg.v[reg_reg.regY])));
                },
                .mvi => emu.reg.i = cur_instr.operands.addr,
                .jmi => emu.reg.pc = cur_instr.operands.addr + @as(chip8_usize, @intCast(emu.reg.v[0])),
                .rand => {
                    const reg_imm = cur_instr.operands.reg_imm;
                    emu.reg.v[reg_imm.regR] = rand.uintAtMost(u8, reg_imm.imm);
                },
                .sprite => if (last_nybble == 0) @panic("super instruction; not implemented") else {
                    const reg_reg_imm = cur_instr.operands.reg_reg_imm;
                    video_changed = true;
                    emu.video.draw_xy(emu, ram_arr[emu.reg.i..][0..reg_reg_imm.imm], emu.reg.v[reg_reg_imm.regR], emu.reg.v[reg_reg_imm.regY]);
                },
                .skpr_skup => switch (nybble_byte.byte) {
                    0x9e => emu.reg.pc += @sizeOf(RomInstruction) *
                        @as(u12, @intFromBool(io_interface.checkKeyIsPressed(@intCast(emu.reg.v[nybble_byte.nybble])) catch false)),
                    0xa1 => emu.reg.pc += @sizeOf(RomInstruction) *
                        @as(u12, @intFromBool(!(io_interface.checkKeyIsPressed(@intCast(emu.reg.v[nybble_byte.nybble])) catch false))),
                    else => unreachable,
                },
                .extra_media => switch (nybble_byte.byte) {
                    0x07 => emu.reg.v[nybble_byte.nybble] = emu.reg.dt,
                    0x0a => emu.reg.v[nybble_byte.nybble] = try io_interface.getKeyBlocking(),
                    0x15 => emu.reg.dt = emu.reg.v[nybble_byte.nybble],
                    0x18 => emu.reg.st = emu.reg.v[nybble_byte.nybble],
                    0x1e => emu.reg.i +%= emu.reg.v[nybble_byte.nybble],
                    0x29 => emu.reg.i = Ram.Offset.font_block + @sizeOf(Ram.CharFont) * @as(u12, emu.reg.v[nybble_byte.nybble]),
                    0x30 => @panic("super instruction; not implemented"),
                    0x33 => bufWriteDecimalByte(ram_arr[emu.reg.i..][0..3], emu.reg.v[nybble_byte.nybble]),
                    0x55 => @memcpy(ram_arr[emu.reg.i..].ptr, emu.reg.v[0 .. @as(usize, nybble_byte.nybble) + 1]),
                    0x65 => @memcpy(emu.reg.v[0 .. @as(usize, nybble_byte.nybble) + 1], ram_arr[emu.reg.i..].ptr),
                    else => unreachable,
                },
            }

            emu.reg.pc += @sizeOf(RomInstruction);

            if (video_changed) {
                io_interface.drawBuffer(&emu.video.raw) catch |e| if (e != error.RangeError) return e;
                video_changed = false;
            }

            if (sixty_hz_flag.load(.acquire)) {
                sixty_hz_flag.store(false, .release);
                if (emu.reg.dt != 0) emu.reg.dt -= 1;
                if (emu.reg.st != 0) {
                    emu.reg.st -= 1;
                    io_interface.beep() catch {};
                }
            }

            // if (should_stop_executing.load(.acquire)) {
            //     break;
            // }

            //std.Thread.sleep(std.time.ns_per_s/80);
        }

        return 0;
    }

    fn sixtyHzThread(sixty_hz_flag: *atomic.Value(bool), should_terminate: *atomic.Value(bool)) void {
        while (!should_terminate.load(.acquire)) {
            sixty_hz_flag.store(true, .release);
            //std.debug.print("timestamp: {d}; updating timers\n", .{std.time.milliTimestamp()});
            std.Thread.sleep(std.time.ns_per_s / 60);
        }
    }

    fn bufWriteDecimalByte(buf: *[3]u8, byte: u8) void {
        buf[2] = byte % 10;
        buf[1] = (byte / 10) % 10;
        buf[0] = byte / 100;
    }

    /// General I/O interface for drawing the video buffer, getting key input, and
    /// (optionally) making a beep sound when the sound timer is decremented.
    /// If sound functions (setupSound, cleanupSound, beep) are left null, no beep
    /// sound will be made.
    pub const IoInterface = struct {
        ptr: *anyopaque,
        vtable: *const VTable,

        const DisplayBuffer = Vram.DisplayBuffer;

        pub const VTable = struct {
            startOutput: *const fn (*anyopaque) OutputError!void,
            startInput: *const fn (*anyopaque) InputError!void,
            setupSound: ?*const fn (*anyopaque) SoundError!void = null,

            endOutput: *const fn (*anyopaque) void,
            endInput: *const fn (*anyopaque) void,
            cleanupSound: ?*const fn (*anyopaque) void = null,

            drawBuffer: *const fn (*anyopaque, buffer: *const [32]u64) OutputError!void,

            getKeyBlocking: *const fn (*anyopaque) InputError!u4,
            checkKeyIsPressed: *const fn (*anyopaque, key: u4) InputError!bool,
            shouldTerminate: *const fn (*anyopaque) InputError!bool,

            beep: ?*const fn (*anyopaque) SoundError!void = null,
        };

        pub const InputError = error{
            OtherError,
            ReadFailed,
        };
        pub const OutputError = error{
            OtherError,
            RangeError,
            WriteFailed,
        };
        pub const SoundError = error{
            OtherError,
            BeepFailed,
            NoSound,
        };
        pub const Error = InputError || OutputError || SoundError;

        pub const terminate_key = '\n';

        pub fn start(self: IoInterface) !void {
            try self.vtable.startOutput(self.ptr);
            try self.vtable.startInput(self.ptr);
            if (self.vtable.setupSound) |setupSound| try setupSound(self.ptr);
        }
        pub fn end(self: IoInterface) void {
            self.vtable.endOutput(self.ptr);
            self.vtable.endInput(self.ptr);
            if (self.vtable.cleanupSound) |cleanupSound| cleanupSound(self.ptr);
        }
        pub fn drawBuffer(self: IoInterface, buffer: *const [32]u64) !void {
            try self.vtable.drawBuffer(self.ptr, buffer);
        }
        pub fn getKeyBlocking(self: IoInterface) !u4 {
            return try self.vtable.getKeyBlocking(self.ptr);
        }
        pub fn checkKeyIsPressed(self: IoInterface, key: u4) !bool {
            return try self.vtable.checkKeyIsPressed(self.ptr, key);
        }
        pub fn shouldTerminate(self: IoInterface) !bool {
            return try self.vtable.shouldTerminate(self.ptr);
        }
        pub fn beep(self: IoInterface) SoundError!void {
            if (self.vtable.beep) |beepFn| try beepFn(self.ptr) else return error.NoSound;
        }

        pub fn asciiToChip8Key(ascii: u8) ?u4 {
            return switch (std.ascii.toLower(ascii)) {
                'x' => 0x0,
                '1' => 0x1,
                '2' => 0x2,
                '3' => 0x3,
                'q' => 0x4,
                'w' => 0x5,
                'e' => 0x6,
                'a' => 0x7,
                's' => 0x8,
                'd' => 0x9,
                'z' => 0xa,
                'c' => 0xb,
                '4' => 0xc,
                'r' => 0xd,
                'f' => 0xe,
                'v' => 0xf,
                else => null,
            };
        }
    };
};

test {
    testing.refAllDecls(as8);
}

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    var ap: ArgParser = try .init(alloc, args);
    defer ap.deinit();

    var err_buf: [512]u8 = undefined;
    var err_writer = std.fs.File.stderr().writer(&err_buf);
    defer err_writer.interface.flush() catch {};

    const filename = try ap.longShortOption([]const u8, "rom-path", 'R', "path to rom (.ch8) to read");
    const as8_path = try ap.longShortOption([]const u8, "asm", 'A', "path to .as8 file to read");
    const help_option = try ap.longShortOption(bool, "help", 'h', "display this help message") orelse false;
    if (help_option or (filename == null and as8_path == null)) {
        if (filename == null and !help_option) {
            std.log.err("{s}: a path to a rom must be passed (with '--rom-path')" ++
                " or a path to a .as8 file must be passed (with '--asm')", .{args[0]});
        }

        ap.printUsage(&err_writer.interface);
        try err_writer.interface.flush();

        return 1;
    }

    if (filename != null and as8_path != null) {
        std.log.err("{s}: the '--rom-path' ('-R') and '--asm' ('-A') options are mutually exclusive.", .{args[0]});

        ap.printUsage(&err_writer.interface);
        try err_writer.interface.flush();

        return 1;
    }

    var rom_read_buf: [1024]u8 = undefined;
    var file_reader: std.fs.File.Reader = undefined;
    var file: std.fs.File = undefined;
    defer file.close();

    var rom_slice: ?[]u8 = null;
    defer if (rom_slice) |rs| alloc.free(rs);

    var rom_reader = if (filename != null) blk: {
        file = std.fs.cwd().openFile(filename.?, .{ .mode = .read_only }) catch {
            std.log.err("{s}: failed to open rom file '{s}'", .{ args[0], filename.? });
            return 2;
        };
        file_reader = file.reader(&rom_read_buf);
        break :blk file_reader.interface;
    } else blk: {
        file = std.fs.cwd().openFile(as8_path.?, .{ .mode = .read_only }) catch {
            std.log.err("{s}: failed to open .as8 file '{s}'", .{ args[0], as8_path.? });
            return 2;
        };
        file_reader = file.reader(&rom_read_buf);

        std.log.info("hi0", .{});
        var as8_state = as8.As8ParserState.init(alloc, &file_reader.interface, &err_writer.interface);
        as8_state.context.filename = as8_path.?;
        std.log.info("beginning parsing", .{});
        as8_state.parse() catch {
            error_msgs.printErrorHeader(&err_writer.interface, .Warn, "as8 parsing failed\n", .{});
            return 3;
        };
        std.log.info("parsed", .{});
        if (as8_state.entries.items.len == 0) {
            error_msgs.printErrorHeader(&err_writer.interface, .Warn, "generated zero entries\n", .{});
        } else {
            error_msgs.printErrorHeader(&err_writer.interface, .Info, "generated {d} entries\n", .{as8_state.entries.items.len});
        }
        try err_writer.interface.flush();

        rom_slice = try alloc.alloc(u8, as8_state.cur_addr - 0x200);

        var fixed_writer = std.Io.Writer.fixed(rom_slice.?);
        for (as8_state.entries.items) |item| {
            try item.serialize(as8_state, &fixed_writer);
        }
        as8_state.deinit();

        break :blk std.Io.Reader.fixed(rom_slice.?);
    };

    var inr_buf: [512]u8 = undefined;
    var inr_freader = std.fs.File.stdin().reader(&inr_buf);
    assert(posix.isatty(std.fs.File.stdin().handle));

    var outw_buf: [512]u8 = undefined;
    var outw_fwriter = std.fs.File.stdout().writer(&outw_buf);
    const outw = &outw_fwriter.interface;

    var termio: Chip8TermIO = .init(&outw_fwriter, &inr_freader, alloc);
    defer termio.deinit();
    const chip8_interface = termio.interface();

    try chip8_interface.start();
    defer chip8_interface.end();

    var chip8 = std.mem.zeroInit(Chip8Emu, .{});
    assert(try chip8.loadRom(&rom_reader) > 0);
    _ = try chip8.emulateProgramData(chip8_interface);

    try outw.flush();

    return 0;
}

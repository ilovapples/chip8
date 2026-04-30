const std = @import("std");
const Io = std.Io;
const atomic = std.atomic;
const builtin = @import("builtin");
const posix = std.posix;
const testing = std.testing;
const assert = std.debug.assert;

const mibu = @import("mibu");
const ArgParser = @import("jitargs").ArgParser;
const rawmode_term = @import("term.zig");

const assembler = @import("assembler.zig");

const error_msgs = @import("error_msgs.zig");

const chip = @import("chip8.zig");
const rom = @import("rom.zig");

const interfaces = @import("interfaces.zig");
const Chip8TermIO = interfaces.Chip8TermIO;

pub const Chip8Emu = struct {
    ram: chip.Ram,

    /// registers
    reg: chip.Registers,

    /// stack. reg.sp points to the top element (current stack frame)
    stack: [16]chip.Addr,

    /// video buffer (64x32 monochrome pixels)
    video: chip.Vram,

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

    fn toBigEndian(v: anytype) @TypeOf(v) {
        return if (builtin.cpu.arch.endian() == .big) v else @byteSwap(v);
    }

    /// emulate the CHIP8 instruction set.
    ///
    /// returns the value in V0 register at termination.
    ///
    /// you probably want to call emu.loadRom first, to load a ROM into memory.
    pub fn emulateProgramData(emu: *Chip8Emu, io: Io, io_interface: IoInterface) !u8 {
        // initialize program counter (link register)
        emu.reg.pc = chip.Ram.offsets.program_data;
        const ram_arr = emu.ram.full();

        var xoshiro = std.Random.Xoshiro256.init(@intCast(@intFromPtr(emu)));
        const rand = xoshiro.random();

        var sixty_hz_flag: atomic.Value(bool) = .init(false);
        var threads_should_terminate: atomic.Value(bool) = .init(false);
        defer threads_should_terminate.store(true, .release);
        var sixty_hz_task = try io.concurrent(sixtyHzThread, .{ io, &sixty_hz_flag });
        defer sixty_hz_task.cancel(io);
        // var should_stop_executing: atomic.Value(bool) = .init(false);
        // _ = try std.Thread.spawn(.{}, checkForTerminateKey, .{
        //     &should_stop_executing,
        //     &threads_should_terminate,
        //     io_interface,
        // });

        var cycle: u64 = 0;
        while (true) : (cycle += 1) {
            const cur_instr: rom.Instruction = @bitCast(toBigEndian(std.mem.bytesToValue(
                u16,
                ram_arr[emu.reg.pc..][0..@sizeOf(rom.Instruction)],
            )));
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
                    emu.reg.pc += @sizeOf(rom.Instruction) *
                        @as(u12, @intCast(@intFromBool(emu.reg.v[reg_imm.regR] == reg_imm.imm)));
                },
                .skne => {
                    const reg_imm = cur_instr.operands.reg_imm;
                    emu.reg.pc += @sizeOf(rom.Instruction) *
                        @as(u12, @intCast(@intFromBool(emu.reg.v[reg_imm.regR] != reg_imm.imm)));
                },
                .skeq_reg => {
                    const reg_reg = cur_instr.operands.reg_reg_unused;
                    emu.reg.pc += @sizeOf(rom.Instruction) *
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
                    emu.reg.pc += @sizeOf(rom.Instruction) *
                        @as(u12, @intCast(@intFromBool(emu.reg.v[reg_reg.regR] != emu.reg.v[reg_reg.regY])));
                },
                .mvi => emu.reg.i = cur_instr.operands.addr,
                .jmi => emu.reg.pc = cur_instr.operands.addr +% @as(chip.Addr, @intCast(emu.reg.v[0])),
                .rand => {
                    const reg_imm = cur_instr.operands.reg_imm;
                    emu.reg.v[reg_imm.regR] = rand.uintAtMost(u8, reg_imm.imm);
                },
                .sprite => if (last_nybble == 0) @panic("super instruction; not implemented") else {
                    const reg_reg_imm = cur_instr.operands.reg_reg_imm;
                    video_changed = true;
                    emu.video.draw_xy(&emu.reg, ram_arr[emu.reg.i..][0..reg_reg_imm.imm], emu.reg.v[reg_reg_imm.regR], emu.reg.v[reg_reg_imm.regY]);
                },
                .skpr_skup => switch (nybble_byte.byte) {
                    0x9e => emu.reg.pc += @sizeOf(rom.Instruction) *
                        @as(u12, @intFromBool(io_interface.checkKeyIsPressed(@intCast(emu.reg.v[nybble_byte.nybble])) catch false)),
                    0xa1 => emu.reg.pc += @sizeOf(rom.Instruction) *
                        @as(u12, @intFromBool(!(io_interface.checkKeyIsPressed(@intCast(emu.reg.v[nybble_byte.nybble])) catch false))),
                    else => unreachable,
                },
                .extra_media => switch (nybble_byte.byte) {
                    0x07 => emu.reg.v[nybble_byte.nybble] = emu.reg.dt,
                    0x0a => emu.reg.v[nybble_byte.nybble] = try io_interface.getKeyBlocking(),
                    0x15 => emu.reg.dt = emu.reg.v[nybble_byte.nybble],
                    0x18 => emu.reg.st = emu.reg.v[nybble_byte.nybble],
                    0x1e => emu.reg.i +%= emu.reg.v[nybble_byte.nybble],
                    0x29 => emu.reg.i = chip.Ram.offsets.font_block + @sizeOf(chip.CharFont) * @as(u12, emu.reg.v[nybble_byte.nybble]),
                    0x30 => @panic("super instruction; not implemented"),
                    0x33 => bufWriteDecimalByte(ram_arr[emu.reg.i..][0..3], emu.reg.v[nybble_byte.nybble]),
                    0x55 => @memcpy(ram_arr[emu.reg.i..].ptr, emu.reg.v[0 .. @as(usize, nybble_byte.nybble) + 1]),
                    0x65 => @memcpy(emu.reg.v[0 .. @as(usize, nybble_byte.nybble) + 1], ram_arr[emu.reg.i..].ptr),
                    else => unreachable,
                },
            }

            emu.reg.pc += @sizeOf(rom.Instruction);

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

    fn sixtyHzThread(io: Io, sixty_hz_flag: *atomic.Value(bool)) void {
        while (true) {
            sixty_hz_flag.store(true, .release);
            //std.debug.print("timestamp: {d}; updating timers\n", .{std.time.milliTimestamp()});
            io.sleep(.fromNanoseconds(std.time.ns_per_s / 60), .awake) catch break;
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

        const DisplayBuffer = chip.Vram.DisplayBuffer;

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
            return self.vtable.getKeyBlocking(self.ptr);
        }
        pub fn checkKeyIsPressed(self: IoInterface, key: u4) !bool {
            return self.vtable.checkKeyIsPressed(self.ptr, key);
        }
        pub fn shouldTerminate(self: IoInterface) !bool {
            return self.vtable.shouldTerminate(self.ptr);
        }
        pub fn beep(self: IoInterface) SoundError!void {
            return if (self.vtable.beep) |beepFn| beepFn(self.ptr) else error.NoSound;
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
    testing.refAllDecls(assembler);
}

const usage_msg =
    \\usage: {s} [-R <file>] [A <file>] [-h]
    \\
    \\options:
    \\  --help, -h                    display this help message
    \\  --rom-path, -R <file>         path to rom (.ch8) to read
    \\  --asm, -A <file>              path to assembly (.as8) file to read
    \\
;

pub fn main(init: std.process.Init.Minimal) !u8 {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var io_threaded: Io.Threaded = .init(gpa, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();

    const args = try init.args.toSlice(arena.allocator());
    var ap: ArgParser = try .init(gpa, args);
    defer ap.deinit();

    var err_buf: [512]u8 = undefined;
    var err_writer = Io.File.stderr().writer(io, &err_buf);
    const stderr = &err_writer.interface;
    defer stderr.flush() catch {};

    const filename = ap.longShortOption([]const u8, "rom-path", 'R');
    const as8_path = ap.longShortOption([]const u8, "asm", 'A');
    const help_option = ap.longShortOption(bool, "help", 'h') orelse false;
    if (help_option or (filename == null and as8_path == null)) {
        if (filename == null and !help_option) {
            std.log.err("{s}: a path to a rom must be passed (with '--rom-path')" ++
                " or a path to a .as8 file must be passed (with '--asm')", .{args[0]});
        }

        try stderr.print(usage_msg, .{args[0]});

        return 1;
    }

    if (filename != null and as8_path != null) {
        std.log.err("{s}: the '--rom-path' ('-R') and '--asm' ('-A') options are mutually exclusive.", .{args[0]});

        try stderr.print(usage_msg, .{args[0]});

        return 1;
    }

    var rom_read_buf: [1024]u8 = undefined;
    var file_reader: Io.File.Reader = undefined;
    var file: Io.File = undefined;
    defer file.close(io);

    var rom_slice: ?[]u8 = null;
    defer if (rom_slice) |rs| gpa.free(rs);

    var rom_reader = if (filename != null) blk: {
        file = Io.Dir.cwd().openFile(io, filename.?, .{ .mode = .read_only }) catch {
            std.log.err("{s}: failed to open rom file '{s}'", .{ args[0], filename.? });
            return 2;
        };
        file_reader = file.reader(io, &rom_read_buf);
        break :blk file_reader.interface;
    } else blk: {
        file = Io.Dir.cwd().openFile(io, as8_path.?, .{ .mode = .read_only }) catch {
            std.log.err("{s}: failed to open .as8 file '{s}'", .{ args[0], as8_path.? });
            return 2;
        };
        file_reader = file.reader(io, &rom_read_buf);

        std.log.info("hi0", .{});
        var as8_state = assembler.As8ParserState.init(gpa, &file_reader.interface, &err_writer.interface);
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

        rom_slice = try gpa.alloc(u8, as8_state.cur_addr - 0x200);

        var fixed_writer = std.Io.Writer.fixed(rom_slice.?);
        for (as8_state.entries.items) |item| {
            try item.serialize(as8_state, &fixed_writer);
        }
        as8_state.deinit();

        break :blk std.Io.Reader.fixed(rom_slice.?);
    };

    var inr_buf: [512]u8 = undefined;
    var inr_freader = Io.File.stdin().reader(io, &inr_buf);
    assert(Io.File.stdin().isTty(io) catch unreachable);

    var outw_buf: [512]u8 = undefined;
    var outw_fwriter = Io.File.stdout().writer(io, &outw_buf);
    const outw = &outw_fwriter.interface;

    var termio: Chip8TermIO = .init(io, &outw_fwriter, &inr_freader, gpa);
    defer termio.deinit();
    const chip8_interface = termio.interface();

    try chip8_interface.start();
    defer chip8_interface.end();

    var chip8_emu = std.mem.zeroInit(Chip8Emu, .{});
    assert(try chip8_emu.loadRom(&rom_reader) > 0);
    _ = try chip8_emu.emulateProgramData(io, chip8_interface);

    try outw.flush();

    return 0;
}

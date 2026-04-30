const std = @import("std");
const chip = @import("chip8.zig");

pub const Instruction = packed struct(u16) {
    operands: Operands,
    category: Category,

    pub const Operands = packed union {
        /// xXXX
        addr: chip.Addr,
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

    /// http://devernay.free.fr/hacks/chip8/chip8def.htm
    pub const Category = enum(u4) {
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
};

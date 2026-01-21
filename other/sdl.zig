const std = @import("std");

const c = @cImport(@cInclude("SDL3/sdl.h"));

pub fn main() !void {
    const texture_width = 64;
    const texture_height = 32;
    const scale = 10;

    _ = c.SDL_SetAppMetadata("chip8 emulator", "0.1.0", "my_app_yay");
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.FailedSDLInit;
    defer c.SDL_Quit();

    const window: ?*c.SDL_Window = c.SDL_CreateWindow("emulator", texture_width * scale, texture_height * scale, 0) orelse {
        std.log.err("{s}", .{std.mem.span(c.SDL_GetError())});
        return error.SDLError;
    };
    defer c.SDL_DestroyWindow(window);

    const renderer: ?*c.SDL_Renderer = c.SDL_CreateRenderer(window, null) orelse {
        std.log.err("{s}", .{std.mem.span(c.SDL_GetError())});
        return error.SDLError;
    };
    defer c.SDL_DestroyRenderer(renderer);
    _ = c.SDL_SetRenderScale(renderer, scale, scale);

    const texture = c.SDL_CreateTexture(renderer, c.SDL_PIXELFORMAT_ARGB8888, c.SDL_TEXTUREACCESS_STREAMING, texture_width, texture_height) orelse {
        std.log.err("{s}", .{std.mem.span(c.SDL_GetError())});
        return error.SDLError;
    };
    defer c.SDL_DestroyTexture(texture);
    //_ = SDL.SDL_SetTextureBlendMode(texture, SDL.SDL_BLENDMODE_NONE);

    const pixel_buf: [32]u64 = .{
        0b00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000,
        0b00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000,
        0b00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000,
        0b00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000,
        0b00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000,
        0b00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000,
        0b00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000,
        0b00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000,
        0b00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000,
        0b00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000,
        0b00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000,
        0b00000000_00000000_00000000_00000000_00000100_00000000_00000000_00000000,
        0b00000000_00000000_00000000_00000000_00001000_00000000_00000000_00000000,
        0b00000000_00000000_00000000_00000000_00010000_00000000_00000000_00000000,
        0b00000000_00000000_00000000_00000000_00100000_00000000_00000000_00000000,
        0b00000000_00000000_00000000_00000000_01000000_00000000_00000000_00000000,
        0b00000000_00000000_00000000_00000000_10000000_00000000_00000000_00000000,
        0b00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000,
        0b00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000,
        0b00000000_00000000_01000000_00000000_00000000_00000000_00000000_00000000,
        0b00000000_00000000_01000000_00000000_00000000_00000000_00000000_00000000,
        0b00000000_00000000_01000000_00000000_00000000_00000000_00000000_00000000,
        0b00000001_00000000_01000000_00000000_00000000_00000000_00000000_00000000,
        0b00000010_00000100_00000000_00000000_00000000_00000000_00000000_00000000,
        0b00000100_00000100_00000000_00000000_00000000_00000000_00000000_00000000,
        0b00011000_00001000_00000000_00000000_00000000_00000000_00000000_00000000,
        0b00100000_00000000_00000000_00000000_00000000_00000000_00000000_00000000,
        0b01000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000,
        0b00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000,
        0b00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000,
        0b00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000,
        0b00000000_00000000_00000000_00000000_00000000_00000000_00000000_00000000,
    };

    var scaled_texture: [texture_height * texture_width]u32 = undefined;
    const argb_white: u32 = 0xFF_FFFFFF;
    const argb_black: u32 = 0xFF_000000;
    for (pixel_buf[0..], 0..) |row, y| {
        for (0..texture_width) |x| {
            const mask: u64 = @as(u64, 1) << 63 - @as(u6, @intCast(x));

            scaled_texture[y * texture_width + x] = if ((row & mask) != 0) argb_white else argb_black;
        }
    }

    if (!c.SDL_UpdateTexture(texture, null, &scaled_texture, texture_width * @sizeOf(u32))) {
        std.log.err("{s}", .{std.mem.span(c.SDL_GetError())});
        return error.SDLError;
    }

    _ = c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
    _ = c.SDL_RenderClear(renderer);
    _ = c.SDL_RenderTexture(renderer, texture, null, null);
    _ = c.SDL_RenderPresent(renderer);

    std.log.info("rendering on '{s}'", .{c.SDL_GetCurrentVideoDriver()});

    c.SDL_PumpEvents();
    var event: c.SDL_Event = undefined;
    outer: while (true) {
        while (c.SDL_PollEvent(&event)) {
            switch (event.type) {
                c.SDL_EVENT_QUIT, c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => break :outer,
                c.SDL_EVENT_KEY_UP, c.SDL_EVENT_KEY_DOWN => switch (event.key.key) {
                    c.SDLK_ESCAPE, c.SDLK_RETURN, c.SDLK_RETURN2 => {
                        std.log.info("exit key pressed!", .{});
                        break :outer;
                    },
                    else => {},
                },
                else => {},
            }
        }
    }
}

const std = @import("std");

const SDL = @cImport(
    @cInclude("SDL3/sdl.h")
);

pub fn main() !void {
    const texture_width = 64;
    const texture_height = 32;
    const scale = 10;

    if (!SDL.SDL_Init(SDL.SDL_INIT_VIDEO)) return error.FailedSDLInit;
    defer SDL.SDL_Quit();

    const window: ?*SDL.SDL_Window = SDL.SDL_CreateWindow("emulator", texture_width * scale, texture_height * scale, 0);
    if (window == null) {
        std.log.err("{s}", .{std.mem.span(SDL.SDL_GetError())});
        return error.SDLError;
    }
    defer SDL.SDL_DestroyWindow(window);

    const renderer: ?*SDL.SDL_Renderer = SDL.SDL_CreateRenderer(window, null);
    if (renderer == null) {
        std.log.err("{s}", .{std.mem.span(SDL.SDL_GetError())});
        return error.SDLError;
    }
    defer SDL.SDL_DestroyRenderer(renderer);

    const texture = SDL.SDL_CreateTexture(
        renderer,
        SDL.SDL_PIXELFORMAT_ARGB8888,
        SDL.SDL_TEXTUREACCESS_STREAMING,
        texture_width,
        texture_height);
    if (texture == null) {
        std.log.err("{s}", .{std.mem.span(SDL.SDL_GetError())});
        return error.SDLError;
    }
    defer SDL.SDL_DestroyTexture(texture);

    var texture_buffer: [texture_height * scale * texture_width * scale]u32 = undefined;
    for (0..texture_height) |y| {
        for (0..texture_width) |x| {
            const val: u32 = if (x%2 == y%2) 0xFF_FFFFFF else 0xFF_000000;

            for (0..scale) |write_y| {
                for (0..scale) |write_x| {
                    @as(*[texture_height * scale][texture_width * scale]u32, @ptrCast(&texture_buffer))[y + write_y][x + write_x] = val;
                }
            }
        }
    }

    if (!SDL.SDL_UpdateTexture(texture, null, &texture_buffer, texture_width*scale*@sizeOf(u32))) {
        std.log.err("{s}", .{std.mem.span(SDL.SDL_GetError())});
        return error.SDLError;
    }
    _ = SDL.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
    _ = SDL.SDL_RenderClear(renderer);
    _ = SDL.SDL_RenderTexture(renderer, texture, null, null);
    _ = SDL.SDL_RenderPresent(renderer);

    std.log.info("rendering on '{s}'", .{SDL.SDL_GetCurrentVideoDriver()});

    SDL.SDL_PumpEvents();
    var event: SDL.SDL_Event = undefined;
    while (true) outer: {
        while (SDL.SDL_PollEvent(&event)) {
            switch (event.type) {
                SDL.SDL_EVENT_QUIT, SDL.SDL_EVENT_WINDOW_CLOSE_REQUESTED => break :outer,
                else => {},
            }
        }
    }
}

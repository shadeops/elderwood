const std = @import("std");
const pdapi = @import("playdate_api_definitions.zig");
const panic_handler = @import("panic_handler.zig");

pub const panic = panic_handler.panic;

const ExampleGlobalState = struct {
    grid_table: *pdapi.LCDBitmapTable,
    grid_map: *pdapi.LCDTileMap,
    playdate: *pdapi.PlaydateAPI,
    posx: i8,
    posy: i8,
    tile_offsetx: i8,
    tile_offsety: i8,
    font: *pdapi.LCDFont,
};

const tile_size = 32;
const screen_tiles_x = @divFloor(pdapi.LCD_COLUMNS, tile_size) + 2;
const screen_tiles_y = @divFloor(pdapi.LCD_ROWS, tile_size) + 2;
const screen_tiles = screen_tiles_x * screen_tiles_y;
const grid_tiles_x = 10;
const grid_tiles_y = 10;

pub export fn eventHandler(playdate: *pdapi.PlaydateAPI, event: pdapi.PDSystemEvent, arg: u32) callconv(.C) c_int {
    //TODO: replace with your own code!

    _ = arg;
    switch (event) {
        .EventInit => {
            //NOTE: Initalizing the panic handler should be the first thing that is done.
            //      If a panic happens before calling this, the simulator or hardware will
            //      just crash with no message.
            panic_handler.init(playdate);

            const grid_table = playdate.graphics.loadBitmapTable("assets/images/grid", null).?;
            const grid_map = playdate.graphics.tilemap.newTilemap().?;
            playdate.graphics.tilemap.setImageTable(grid_map, grid_table);

            const font = playdate.graphics.loadFont("/System/Fonts/Roobert-11-Medium.pft", null).?;
            playdate.graphics.setFont(font);

            const global_state: *ExampleGlobalState =
                @ptrCast(
                    @alignCast(
                        playdate.system.realloc(
                            null,
                            @sizeOf(ExampleGlobalState),
                        ),
                    ),
                );
            global_state.* = .{
                .grid_table = grid_table,
                .grid_map = grid_map,
                .playdate = playdate,
                .posx = 0,
                .posy = 0,
                .tile_offsetx = 4,
                .tile_offsety = 4,
                .font = font,
            };

            playdate.system.setUpdateCallback(update_and_render, global_state);
        },
        else => {},
    }
    return 0;
}

fn update_and_render(userdata: ?*anyopaque) callconv(.C) c_int {
    //TODO: replace with your own code!

    const global_state: *ExampleGlobalState = @ptrCast(@alignCast(userdata.?));
    const playdate = global_state.playdate;
    const tile_map = global_state.grid_map;

    const draw_mode: pdapi.LCDBitmapDrawMode = .DrawModeCopy;
    const clear_color: pdapi.LCDSolidColor = .ColorWhite;

    var current_buttons: pdapi.PDButtons = undefined;
    var pushed_buttons: pdapi.PDButtons = undefined;
    var released_buttons: pdapi.PDButtons = undefined;
    playdate.system.getButtonState(&current_buttons, &pushed_buttons, &released_buttons);

    if (pdapi.BUTTON_LEFT & current_buttons != 0) global_state.posx += 1;
    if (pdapi.BUTTON_RIGHT & current_buttons != 0) global_state.posx -= 1;
    if (pdapi.BUTTON_UP & current_buttons != 0) global_state.posy += 1;
    if (pdapi.BUTTON_DOWN & current_buttons != 0) global_state.posy -= 1;

    if (global_state.posx > 0) {
        global_state.tile_offsetx -= 1;
        global_state.posx = global_state.posx - tile_size;
    } else if (global_state.posx <= -tile_size) {
        global_state.tile_offsetx += 1;
        global_state.posx = @rem(global_state.posx, tile_size);
    }
    if (global_state.posy > 0) {
        global_state.tile_offsety -= 1;
        global_state.posy = global_state.posy - tile_size;
    } else if (global_state.posy <= -tile_size) {
        global_state.tile_offsety += 1;
        global_state.posy = @mod(global_state.posy, tile_size);
    }

    global_state.tile_offsetx = @rem(global_state.tile_offsetx, grid_tiles_x);
    global_state.tile_offsety = @rem(global_state.tile_offsety, grid_tiles_y);

    playdate.graphics.setDrawMode(draw_mode);
    playdate.graphics.clear(@intCast(@intFromEnum(clear_color)));

    var tile_idxs = [_]u16{0} ** (screen_tiles);
    for (&tile_idxs, 0..) |*t, i| {
        // screen tiles
        // x: 0 -> 14
        // y: 0 -> 9
        const screen_row: i32 = @intCast(i / screen_tiles_x);
        const screen_col: i32 = @intCast(i % screen_tiles_x);
        const x_tile: i32 = global_state.tile_offsetx + @mod(screen_col, grid_tiles_x);
        const y_tile: i32 = global_state.tile_offsety + @mod(screen_row, grid_tiles_y);
        t.* = @intCast(@mod(y_tile, grid_tiles_y) * grid_tiles_x + @mod(x_tile, grid_tiles_x));
    }
    playdate.graphics.tilemap.setTiles(tile_map, &tile_idxs, tile_idxs.len, screen_tiles_x);
    playdate.graphics.tilemap.drawAtPoint(
        tile_map,
        @floatFromInt(global_state.posx),
        @floatFromInt(global_state.posy),
    );

    if (true) {
        var buffer: [*c]u8 = null;
        const str_len = playdate.system.formatString(
            &buffer,
            "offsetx: %d\noffsety: %d\nposx: %d\nposy: %d",
            global_state.tile_offsetx,
            global_state.tile_offsety,
            global_state.posx,
            global_state.posy,
        );
        if (buffer != null) {
            playdate.graphics.fillRect(90, 50, 150, 100, @intFromEnum(clear_color));
            const pixel_width = playdate.graphics.drawText(@ptrCast(buffer.?), @intCast(str_len), .UTF8Encoding, 100, 50);
            _ = playdate.system.realloc(@ptrCast(buffer), 0);
            buffer = null;
            _ = pixel_width;
        }
    }

    //returning 1 signals to the OS to draw the frame.
    //we always want this frame drawn
    return 1;
}

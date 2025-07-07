const std = @import("std");
const builtin = @import("builtin");
const pdapi = @import("playdate_api_definitions.zig");
const panic_handler = @import("panic_handler.zig");

const BitmapLib = @import("BitmapLib.zig");
const Level = @import("Level.zig");

const base_types = @import("base_types.zig");
const Position = base_types.Position;

const debug = builtin.mode == .Debug;

pub const panic = panic_handler.panic;

const GlobalState = struct {
    playdate: *pdapi.PlaydateAPI,
    pos: Position,
    bitlib: BitmapLib,
    level: Level,
    frame: u8,
    flipped: bool,
};

pub export fn eventHandler(playdate: *pdapi.PlaydateAPI, event: pdapi.PDSystemEvent, arg: u32) callconv(.C) c_int {
    _ = arg;
    switch (event) {
        .EventInit => {
            panic_handler.init(playdate);

            var bitmap_lib = BitmapLib.init(playdate);
            var bitmap_lib_parser = BitmapLib.BitmapLibParser{ .bitlib = &bitmap_lib };
            bitmap_lib_parser.buildLibrary();

            var level = Level.init(playdate, bitmap_lib);
            var level_parser = Level.LevelParser{ .level = &level };
            level_parser.buildLevel();
            level.populate();

            const global_state: *GlobalState =
                @ptrCast(@alignCast(
                    playdate.system.realloc(null, @sizeOf(GlobalState)),
                ));
            global_state.* = .{
                .playdate = playdate,
                .pos = .{ .x = 0, .y = 0 },
                .frame = 0,
                .flipped = false,
                .bitlib = bitmap_lib,
                .level = level,
            };

            playdate.system.setUpdateCallback(update_and_render, global_state);
        },
        else => {},
    }
    return 0;
}

fn update_and_render(userdata: ?*anyopaque) callconv(.C) c_int {
    const global_state: *GlobalState = @ptrCast(@alignCast(userdata.?));
    const playdate = global_state.playdate;

    const draw_mode: pdapi.LCDBitmapDrawMode = .DrawModeCopy;
    playdate.graphics.setDrawMode(draw_mode);

    var current_buttons: pdapi.PDButtons = undefined;
    var pushed_buttons: pdapi.PDButtons = undefined;
    var released_buttons: pdapi.PDButtons = undefined;
    playdate.system.getButtonState(&current_buttons, &pushed_buttons, &released_buttons);

    var delta = Position{ .x = 0, .y = 0 };
    if (pdapi.BUTTON_LEFT & current_buttons != 0) delta.x = -2;
    if (pdapi.BUTTON_RIGHT & current_buttons != 0) delta.x = 2;
    if (pdapi.BUTTON_UP & current_buttons != 0) delta.y = -2;
    if (pdapi.BUTTON_DOWN & current_buttons != 0) delta.y = 2;

    global_state.pos.x += delta.x;
    global_state.pos.y += delta.y;

    if (delta.x < 0) global_state.flipped = true;
    if (delta.x > 0) global_state.flipped = false;

    playdate.sprite.updateAndDrawSprites();

    playdate.graphics.drawBitmap(
        global_state.bitlib.bitmaps[global_state.frame + 1],
        @as(c_int, global_state.pos.x),
        @as(c_int, global_state.pos.y),
        if (global_state.flipped) .BitmapFlippedXY else .BitmapFlippedY,
    );
    if (delta.x != 0 or delta.y != 0) global_state.frame = (global_state.frame + 1) % 18;

    return 1;
}

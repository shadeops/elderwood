const std = @import("std");
const builtin = @import("builtin");
const pdapi = @import("playdate_api_definitions.zig");
const panic_handler = @import("panic_handler.zig");

const BitmapLib = @import("BitmapLib.zig");
const Level = @import("Level.zig");
const Player = @import("Player.zig");

const base_types = @import("base_types.zig");
const Position = base_types.Position;

const debug = builtin.mode == .Debug;

pub const panic = panic_handler.panic;

const GlobalState = struct {
    playdate: *const pdapi.PlaydateAPI,
    bitlib: *const BitmapLib,
    level: *const Level,
    player: *const Player,
};

pub export fn eventHandler(playdate: *pdapi.PlaydateAPI, event: pdapi.PDSystemEvent, arg: u32) callconv(.C) c_int {
    _ = arg;
    switch (event) {
        .EventInit => {
            panic_handler.init(playdate);

            const bitmap_lib = BitmapLib.init(playdate);
            var bitmap_lib_parser = BitmapLib.BitmapLibParser{ .bitlib = bitmap_lib };
            bitmap_lib_parser.buildLibrary();

            var level = Level.init(playdate, bitmap_lib);
            var level_parser = Level.LevelParser{ .level = level };
            level_parser.buildLevel();
            level.populate();
            
            const player = Player.init(playdate, bitmap_lib, 0, 18) catch unreachable;
            playdate.sprite.addSprite(player.sprite);
            
            const bitmap = playdate.graphics.newBitmap(200, 50, @intFromEnum(pdapi.LCDSolidColor.ColorClear));
            const sprite = playdate.sprite.newSprite();
            playdate.sprite.setImage(sprite, bitmap, .BitmapUnflipped);
            playdate.sprite.setCenter(sprite, 0, 0);
            playdate.sprite.setSize(sprite, 200, 50);
            playdate.sprite.moveTo(sprite, 50, 100);
            playdate.sprite.setCollisionsEnabled(sprite, 1);
            playdate.sprite.setCollideRect(sprite, .{ .x = 0.0, .y = 0.0, .width = 200.0, .height = 50.0 });
            playdate.sprite.setTag(sprite, 5);
            playdate.sprite.addSprite(sprite);

            const global_state: *GlobalState =
                @ptrCast(@alignCast(
                    playdate.system.realloc(null, @sizeOf(GlobalState)),
                ));
            global_state.* = .{
                .playdate = playdate,
                .bitlib = bitmap_lib,
                .level = level,
                .player = player,
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

    playdate.sprite.updateAndDrawSprites();
    return 1;
}

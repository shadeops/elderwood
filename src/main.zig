const debug = builtin.mode == .Debug;

pub const panic = panic_handler.panic;

const GameControl = enum {
    player,
    level_switch,
};

const SwitchType = enum {
// Denotes the direction the screen wipes
// ie, the player exits right, and the screen slides
// from right to the left replacing the current level.
    none,
    right_to_left,
    left_to_right,
    top_to_bottom,
    bottom_to_top,
};

const LevelTransition = struct {
    from: ?*const Level = null,
    to: ?*const Level = null,
    stype: SwitchType = .none,
    tick: i32 = 0,
};

const GlobalState = struct {
    playdate: *const pdapi.PlaydateAPI,
    bitlib: *const BitmapLib,
    level: *const Level,
    level2: *const Level,
    player: *const Player,
    level_switch: LevelTransition = .{},
};

const level_json = @embedFile("level.json");

pub export fn eventHandler(playdate: *pdapi.PlaydateAPI, event: pdapi.PDSystemEvent, arg: u32) callconv(.C) c_int {
    _ = arg;
    switch (event) {
        .EventInit => {
            panic_handler.init(playdate);

            const bitmap_lib = BitmapLib.init(playdate);
            var bitmap_lib_parser = BitmapLib.BitmapLibParser{ .bitlib = bitmap_lib };
            bitmap_lib_parser.buildLibrary(.{.file = "library"});

            var level = Level.init(playdate, bitmap_lib);
            var level_parser = Level.LevelParser{ .level = level };
            level_parser.buildLevel(.{.file = "grass_planes"});
            level.populate();
            
            const level2 = Level.init(playdate, bitmap_lib);
            level_parser = Level.LevelParser{ .level = level2 };
            level_parser.buildLevel(.{.file = "forest_entrance"});

            const player = Player.init(playdate, bitmap_lib, 0, 18) catch unreachable;
            playdate.sprite.addSprite(player.sprite);

            //const bitmap = playdate.graphics.newBitmap(200, 50, @intFromEnum(pdapi.LCDSolidColor.ColorBlack));
            //const sprite = playdate.sprite.newSprite();
            //playdate.sprite.setImage(sprite, bitmap, .BitmapUnflipped);
            //playdate.sprite.setCenter(sprite, 0, 0);
            //playdate.sprite.setSize(sprite, 200, 50);
            //playdate.sprite.moveTo(sprite, 50, 100);
            //playdate.sprite.setCollisionsEnabled(sprite, 1);
            //playdate.sprite.setCollideRect(sprite, .{ .x = 0.0, .y = 0.0, .width = 200.0, .height = 50.0 });
            //playdate.sprite.setVisible(sprite, 0);
            //playdate.sprite.setTag(sprite, 5);
            //playdate.sprite.addSprite(sprite);

            const global_state: *GlobalState =
                @ptrCast(@alignCast(
                    playdate.system.realloc(null, @sizeOf(GlobalState)),
                ));
            global_state.* = .{
                .playdate = playdate,
                .bitlib = bitmap_lib,
                .level = level,
                .level2 = level2,
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

    if (pdapi.BUTTON_A & released_buttons != 0 and global_state.level_switch.stype == .none) {
        playdate.system.logToConsole("SWITCH!");
        global_state.level_switch = .{
            .from = global_state.level,
            .to = global_state.level2,
            .stype = .right_to_left,
            .tick = 0,
        };
    }

    switch (global_state.level_switch.stype) {
        .right_to_left => {
            const ls = &global_state.level_switch;
            const to = ls.to orelse { ls.* = .{}; return 1; };
            const from = ls.from orelse { ls.* = .{}; return 1; };

            if (ls.tick == 0 ) {
                defer ls.tick += 4;
                // offset from default pos to one screen away
                for (to.sprites) |sprite| {
                    playdate.sprite.moveBy(sprite, 400.0, 0.0);
                }
               to.populate();
            } else if (ls.tick > 400) {
                ls.tick = 0;
                ls.stype = .none;
                from.clear();
                // reset these sprites back to their original position
                for (from.sprites) |sprite| {
                    playdate.sprite.moveBy(sprite, -400.0, 0.0);
                }
                ls.to = null;
                ls.from = null;
            } else {
                defer ls.tick += 4;
                for (to.sprites) |sprite| {
                    playdate.sprite.moveBy(sprite, -4.0, 0.0);
                }
                for (from.sprites) |sprite| {
                    playdate.sprite.moveBy(sprite, -4.0, 0.0);
                }
            }
            playdate.sprite.drawSprites();
            return 1;
        },
        else => {},
    }

    playdate.sprite.updateAndDrawSprites();
    return 1;
}


const std = @import("std");
const builtin = @import("builtin");
const pdapi = @import("playdate_api_definitions.zig");
const panic_handler = @import("panic_handler.zig");

const BitmapLib = @import("BitmapLib.zig");
const Level = @import("Level.zig");
const Player = @import("Player.zig");


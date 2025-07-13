const debug = builtin.mode == .Debug;

pub const panic = panic_handler.panic;

pub export fn eventHandler(playdate: *pdapi.PlaydateAPI, event: pdapi.PDSystemEvent, arg: u32) callconv(.C) c_int {
    _ = arg;
    switch (event) {
        .EventInit => {
            panic_handler.init(playdate);

            const bitmap_lib = BitmapLib.init(playdate);
            var bitmap_lib_parser = BitmapLib.BitmapLibParser{ .bitlib = bitmap_lib };
            bitmap_lib_parser.buildLibrary(.{ .file = "library" });

            const player = Player.init(playdate, bitmap_lib, 0, 18) catch unreachable;
            playdate.sprite.addSprite(player.sprite);

            const map = Map.init(playdate);
            var map_parser = Map.MapParser{ .map = map, .bitlib = bitmap_lib };
            map_parser.buildMap(.{ .file = "map" });
            const current_level = map.starting_level;
            map.buildLevelSwitches();
            map.setLevelTags(current_level);

            playdate.sprite.moveTo(player.sprite, @floatFromInt(map.player_pos_x), @floatFromInt(map.player_pos_y));

            var level = map.levels[current_level];
            level.populate();

            const global_state: *GlobalState =
                @ptrCast(@alignCast(
                    playdate.system.realloc(null, @sizeOf(GlobalState)),
                ));
            global_state.* = .{
                .playdate = playdate,
                .current_level = current_level,
                .map = map,
                .player = player,
            };
            Player.global_gamestate_ptr = global_state;
            playdate.system.setUpdateCallback(update_and_render, global_state);
        },
        else => {},
    }
    return 0;
}

fn update_and_render(userdata: ?*anyopaque) callconv(.C) c_int {
    var global_state: *GlobalState = @ptrCast(@alignCast(userdata.?));
    const playdate = global_state.playdate;

    const draw_mode: pdapi.LCDBitmapDrawMode = .DrawModeCopy;
    playdate.graphics.setDrawMode(draw_mode);

    var current_buttons: pdapi.PDButtons = undefined;
    var pushed_buttons: pdapi.PDButtons = undefined;
    var released_buttons: pdapi.PDButtons = undefined;
    playdate.system.getButtonState(&current_buttons, &pushed_buttons, &released_buttons);

    if (global_state.level_switch.stype != .none) {
        var offsets = [_]f32{0.0} ** 2;
        const ls = &global_state.level_switch;
        const to = ls.to orelse {
            ls.* = .{};
            return 1;
        };
        const from = ls.from orelse {
            ls.* = .{};
            return 1;
        };

        const tick_halt: u32 = switch (global_state.level_switch.stype) {
            .right_to_left, .left_to_right => 400,
            .top_to_bottom, .bottom_to_top => 240,
            else => unreachable,
        };
        if (ls.tick == @as(u32, 0)) {
            defer ls.tick += 4;
            // offset from default pos to one screen away
            offsets = switch (global_state.level_switch.stype) {
                .right_to_left => .{ 400.0, 0.0 },
                .left_to_right => .{ -400.0, 0.0 },
                .top_to_bottom => .{ 0.0, -240.0 },
                .bottom_to_top => .{ 0.0, 240.0 },
                else => unreachable,
            };
            for (to.sprites) |sprite| {
                playdate.sprite.moveBy(sprite, offsets[0], offsets[1]);
            }
            to.populate();
        } else if (ls.tick > tick_halt) {
            // reset these sprites back to their original position
            offsets = switch (global_state.level_switch.stype) {
                .right_to_left => .{ 400.0, 0.0 },
                .left_to_right => .{ -400.0, 0.0 },
                .top_to_bottom => .{ 0.0, -240.0 },
                .bottom_to_top => .{ 0.0, 240.0 },
                else => unreachable,
            };
            ls.tick = 0;
            ls.stype = .none;
            from.clear();
            for (from.sprites) |sprite| {
                playdate.sprite.moveBy(sprite, offsets[0], offsets[1]);
            }
            ls.to = null;
            ls.from = null;
            global_state.map.setLevelTags(global_state.current_level);
        } else {
            defer ls.tick += 4;
            offsets = switch (global_state.level_switch.stype) {
                .right_to_left => .{ -4.0, 0.0 },
                .left_to_right => .{ 4.0, 0.0 },
                .top_to_bottom => .{ 0.0, 4.0 },
                .bottom_to_top => .{ 0.0, -4.0 },
                else => unreachable,
            };
            for (to.sprites) |sprite| {
                playdate.sprite.moveBy(sprite, offsets[0], offsets[1]);
            }
            for (from.sprites) |sprite| {
                playdate.sprite.moveBy(sprite, offsets[0], offsets[1]);
            }
            var x: f32 = 0.0;
            var y: f32 = 0.0;
            playdate.sprite.getPosition(global_state.player.sprite, &x, &y);
            switch (global_state.level_switch.stype) {
                // TODO these offsets should take player sprite size into account
                .right_to_left => {
                    if (x > 4.0)
                        playdate.sprite.moveBy(global_state.player.sprite, offsets[0], offsets[1]);
                },
                .left_to_right => {
                    if (x < 340.0)
                        playdate.sprite.moveBy(global_state.player.sprite, offsets[0], offsets[1]);
                },
                .top_to_bottom => {
                    if (y < 172.0)
                        playdate.sprite.moveBy(global_state.player.sprite, offsets[0], offsets[1]);
                },
                .bottom_to_top => {
                    if (y > -4.0)
                        playdate.sprite.moveBy(global_state.player.sprite, offsets[0], offsets[1]);
                },
                else => unreachable,
            }
        }
        playdate.sprite.drawSprites();
        return 1;
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
const Map = @import("Map.zig");
const Player = @import("Player.zig");
const GlobalState = @import("GlobalState.zig");

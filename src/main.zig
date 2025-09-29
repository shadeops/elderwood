const enable_debug = false;
const debug = if (builtin.mode == .Debug and enable_debug) true else false;

pub const panic = panic_handler.panic;
const playdate = @import("PDapi.zig");

pub export fn eventHandler(playdate_ptr: *pdapi.PlaydateAPI, event: pdapi.PDSystemEvent, arg: u32) callconv(.C) c_int {
    _ = arg;
    switch (event) {
        .EventInit => {
            panic_handler.init(playdate_ptr);

            playdate.set_api(playdate_ptr);
            playdate.system = playdate_ptr.system;
            const global_state: *GlobalState =
                @ptrCast(@alignCast(
                    playdate.system.realloc(null, @sizeOf(GlobalState)),
                ));

            global_state.* = .{
                .state = .init,
                .bitmap_lib = .default,
                .font = playdate.graphics.loadFont("/System/Fonts/Roobert-20-Medium.pft", null).?,
                .hou_img = playdate.graphics.loadBitmap("assets/images/houdini_connect", null).?,
                .map = .default,
                .player = null,
            };
            playdate.system.logToConsole("INIT DONE");
            playdate.system.setUpdateCallback(update_and_render, global_state);
        },
        else => {},
    }
    return 0;
}

fn HTTPAccessCallback(allowed: bool, userdata: ?*anyopaque) callconv(.C) void {
    var global_state: *GlobalState = @ptrCast(@alignCast(userdata.?));
    playdate.system.logToConsole("HTTPAccessCallback: %i", allowed);
    global_state.state = .init;
}

fn update_and_render(userdata: ?*anyopaque) callconv(.C) c_int {
    var global_state: *GlobalState = @ptrCast(@alignCast(userdata.?));

    switch (global_state.state) {
        .play => {},
        .http_request_access => {
            playdate.system.logToConsole("Requesting Access");
            const status = playdate.network.http.requestAccess(
                "localhost",
                65433,
                false,
                "Elderwoods",
                HTTPAccessCallback,
                @ptrCast(global_state),
            );
            //const status = http.requestAccess("localhost", 65433, false, "Elderwoods", null, null);
            if (debug) playdate.system.logToConsole("Access: %i", @intFromEnum(status));
            global_state.state = switch (status) {
                .AccessAsk => .http_wait_for_access,
                .AccessDeny => .init,
                .AccessAllow => .init,
            };
            return 0;
        },
        .build_library => {
            if (!global_state.bitmap_lib.isEmpty()) global_state.bitmap_lib.clear();
            BitmapLib.buildLibrary(global_state);
            return 0;
        },
        .build_map => {
            // Triggers a build of the map, can't interact with the map until the
            // .init_map phase incase there is a http get event
            Map.buildMap(global_state);
            return 0;
        },
        .init_map => {
            defer global_state.state = .init;
            global_state.map.current_level = global_state.map.starting_level;
            global_state.map.buildLevelSwitches();
            global_state.map.setLevelTags();
            if (debug) {
                for (global_state.map.levels, 0..) |level, i| {
                    playdate.system.logToConsole("Level: %d has %d sprites", i, level.sprites.len);
                }
            }
            return 0;
        },
        .init => {
            const bitmap_lib = &global_state.bitmap_lib;
            if (bitmap_lib.isEmpty()) {
                playdate.system.logToConsole("Need to build bitmap lib");
                global_state.state = .build_library;
                return 0;
            }

            if (global_state.map.isEmpty()) {
                playdate.system.logToConsole("Need to build map");
                global_state.state = .build_map;
                return 0;
            }

            const player = Player.init(bitmap_lib, 0, 18) catch unreachable;
            playdate.sprite.addSprite(player.sprite);

            playdate.sprite.moveTo(
                player.sprite,
                @floatFromInt(global_state.map.player_pos_x),
                @floatFromInt(global_state.map.player_pos_y),
            );
            playdate.sprite.setZIndex(
                player.sprite,
                @intCast(global_state.map.player_pos_y),
            );

            global_state.map.levels[global_state.map.current_level].populate();

            global_state.state = .play;
            global_state.player = player;

            Player.global_gamestate_ptr = global_state;
            return 0;
        },
        .http_wait_for_response => {
            playdate.graphics.drawBitmap(global_state.hou_img, 0, 0, .BitmapUnflipped);
            return 1;
        },
        else => return 0,
    }

    const draw_mode: pdapi.LCDBitmapDrawMode = .DrawModeCopy;
    playdate.graphics.setDrawMode(draw_mode);

    var current_buttons: pdapi.PDButtons = undefined;
    var pushed_buttons: pdapi.PDButtons = undefined;
    var released_buttons: pdapi.PDButtons = undefined;
    playdate.system.getButtonState(&current_buttons, &pushed_buttons, &released_buttons);

    if (global_state.level_switch.stype != .none) {
        var offsets: [2]f32 = @splat(0.0);
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
            global_state.map.setLevelTags();
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
            const player = global_state.player.?;
            playdate.sprite.getPosition(player.sprite, &x, &y);
            switch (global_state.level_switch.stype) {
                // TODO these offsets should take player sprite size into account
                .right_to_left => {
                    if (x > 4.0)
                        playdate.sprite.moveBy(player.sprite, offsets[0], offsets[1]);
                },
                .left_to_right => {
                    if (x < 340.0)
                        playdate.sprite.moveBy(player.sprite, offsets[0], offsets[1]);
                },
                .top_to_bottom => {
                    if (y < 172.0)
                        playdate.sprite.moveBy(player.sprite, offsets[0], offsets[1]);
                },
                .bottom_to_top => {
                    if (y > -4.0)
                        playdate.sprite.moveBy(player.sprite, offsets[0], offsets[1]);
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

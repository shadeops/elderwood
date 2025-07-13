
pub const SwitchType = enum {
// Denotes the direction the screen wipes
// ie, the player exits right, and the screen slides
// from right to the left replacing the current level.
    none,
    right_to_left,
    left_to_right,
    top_to_bottom,
    bottom_to_top,
};

pub const LevelTransition = struct {
    from: ?*const Level = null,
    to: ?*const Level = null,
    stype: SwitchType = .none,
    tick: i32 = 0,
};

playdate: *const pdapi.PlaydateAPI,
current_level: usize,
player: *const Player,
map: *Map,
level_switch: LevelTransition = .{},

const std = @import("std");
const pdapi = @import("playdate_api_definitions.zig");

const BitmapLib = @import("BitmapLib.zig");
const Level = @import("Level.zig");
const Map = @import("Map.zig");
const Player = @import("Player.zig");

pub const GameState = enum {
    init,
    build_library,
    build_map,
    init_map,
    build_level,
    http_request_access,
    http_wait_for_access,
    http_get,
    http_wait_for_response,
    play,
};

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

const playdate = @import("PDapi.zig");

state: GameState,
bitmap_lib: BitmapLib = .default,
bitmap_lib_src: JsonSource = .{ .file = "library" },
//bitmap_lib_src: JsonSource = .{ .http = .{ .path = "/bitmap_library" } },

map: Map = .default,
map_src: JsonSource = .{ .file = "map" },
//map_src: JsonSource = .{ .http = .{ .path = "/map" } },

player: ?*const Player,

level_switch: LevelTransition = .{},

font: *pdapi.LCDFont,
hou_img: *pdapi.LCDBitmap,

const std = @import("std");
const pdapi = @import("playdate_api_definitions.zig");

const BitmapLib = @import("BitmapLib.zig");
const Level = @import("Level.zig");
const Map = @import("Map.zig");
const Player = @import("Player.zig");
const JsonSource = @import("base_types.zig").JsonSource;

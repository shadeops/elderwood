const enable_debug = false;
const debug = if (builtin.mode == .Debug and enable_debug) true else false;

const playdate = @import("PDapi.zig");

const Map = @This();

const LevelSwitch = struct {
    east: u8 = 255,
    north: u8 = 255,
    west: u8 = 255,
    south: u8 = 255,
};

const CardinalDirection = enum(u2) {
    north = 0,
    east = 1,
    west = 2,
    south = 3,
};

pub const default: Map = .{
    .levels = &.{},
    .level_switches = &.{},
    .colliders = undefined, // n | e | w | s
    .starting_level = 0,
    .current_level = 0,
    .collision_pad = 4,
    .player_pos_x = 0,
    .player_pos_y = 0,
};

levels: []*Level,
level_switches: []LevelSwitch,
colliders: [4]*pdapi.LCDSprite,
starting_level: u8,
current_level: u8,
collision_pad: u8,
player_pos_x: i32,
player_pos_y: i32,

pub fn isEmpty(self: *const Map) bool {
    return self.levels.len == 0;
}

pub fn clear(self: *Map) void {
    for (self.levels) |level| {
        level.deinit();
    }
    _ = playdate.system.realloc(self.levels.ptr, 0);
    _ = playdate.system.realloc(self.level_switches.ptr, 0);
    self.levels = &.{};
    self.level_switches = &.{};
    for (self.colliders) |collider| {
        playdate.sprite.freeSprite(collider);
    }
}

pub fn buildLevelSwitches(self: *Map) void {
    const north_south_bitmap = playdate.graphics.newBitmap(400, 4, @intFromEnum(pdapi.LCDSolidColor.ColorBlack));
    const east_west_bitmap = playdate.graphics.newBitmap(4, 240, @intFromEnum(pdapi.LCDSolidColor.ColorBlack));

    const north = playdate.sprite.newSprite() orelse unreachable;
    playdate.sprite.setImage(north, north_south_bitmap, .BitmapUnflipped);
    playdate.sprite.setCenter(north, 0, 0);
    playdate.sprite.setSize(north, 400.0, 4.0);
    playdate.sprite.setCollisionsEnabled(north, 1);
    playdate.sprite.setCollideRect(north, .{ .x = 0.0, .y = 0.0, .width = 400.0, .height = 4.0 });
    playdate.sprite.setVisible(north, 0);
    const south = playdate.sprite.copy(north) orelse unreachable;
    playdate.sprite.moveTo(north, 0.0, -@as(f32, @floatFromInt(self.collision_pad)));
    playdate.sprite.moveTo(south, 0.0, @as(f32, 240.0) + @as(f32, @floatFromInt(self.collision_pad)));

    self.colliders[@intFromEnum(CardinalDirection.north)] = north;
    self.colliders[@intFromEnum(CardinalDirection.south)] = south;

    const east = playdate.sprite.newSprite() orelse unreachable;
    playdate.sprite.setImage(east, east_west_bitmap, .BitmapUnflipped);
    playdate.sprite.setCenter(east, 0, 0);
    playdate.sprite.setSize(east, 4.0, 240.0);
    playdate.sprite.setCollisionsEnabled(east, 1);
    playdate.sprite.setCollideRect(east, .{ .x = 0.0, .y = 0.0, .height = 240.0, .width = 4.0 });
    playdate.sprite.setVisible(east, 0);
    const west = playdate.sprite.copy(east) orelse unreachable;
    playdate.sprite.moveTo(east, @as(f32, 400.0) + @as(f32, @floatFromInt(self.collision_pad)), 0.0);
    playdate.sprite.moveTo(west, -@as(f32, @floatFromInt(self.collision_pad)), 0.0);

    self.colliders[@intFromEnum(CardinalDirection.east)] = east;
    self.colliders[@intFromEnum(CardinalDirection.west)] = west;

    for (&self.colliders) |collider| {
        playdate.sprite.addSprite(collider);
    }
}

pub fn setLevelTags(self: *Map) void {
    if (self.current_level >= self.level_switches.len) return;
    const lswitch = self.level_switches[self.current_level];

    const north = self.colliders[@intFromEnum(CardinalDirection.north)];
    const south = self.colliders[@intFromEnum(CardinalDirection.south)];
    const east = self.colliders[@intFromEnum(CardinalDirection.east)];
    const west = self.colliders[@intFromEnum(CardinalDirection.west)];
    playdate.sprite.setTag(north, lswitch.north);
    playdate.sprite.setTag(south, lswitch.south);
    playdate.sprite.setTag(east, lswitch.east);
    playdate.sprite.setTag(west, lswitch.west);
}

pub const MapParser = struct {
    added_levels: u8 = 0,
    current_level_switch: ?*LevelSwitch = null,

    game_state: *GlobalState,

    fn decodeError(decoder: ?*pdapi.JSONDecoder, jerror: ?[*:0]const u8, linenum: c_int) callconv(.C) void {
        _ = decoder;
        playdate.system.logToConsole("ERROR: decodeError: %s %d", jerror, linenum);
    }

    fn willDecodeSublist(decoder: ?*pdapi.JSONDecoder, name: ?[*:0]const u8, jtype: pdapi.JSONValueType) callconv(.C) void {
        const map_parser: *MapParser = @ptrCast(@alignCast((decoder orelse return).userdata));
        const map = &map_parser.game_state.map;
        if (debug) playdate.system.logToConsole("[%s] willDecodeSublist: %s, [%d]", decoder.?.path, name, @intFromEnum(jtype));

        const key_name = std.mem.sliceTo(name orelse return, 0);

        if (jtype == .JSONTable and std.mem.eql(u8, "level", key_name)) {
            map_parser.current_level_switch = &map.level_switches[map_parser.added_levels];
        }
    }

    fn didDecodeTableValue(decoder: ?*pdapi.JSONDecoder, key: ?[*:0]const u8, value: pdapi.JSONValue) callconv(.C) void {
        const map_parser: *MapParser = @ptrCast(@alignCast((decoder orelse return).userdata));

        const cls = map_parser.current_level_switch;
        const map = &map_parser.game_state.map;
        if (debug) playdate.system.logToConsole("[%s] didDecodeTableValue: %s [%d]", decoder.?.path, key, value.type);

        const key_name = std.mem.sliceTo(key orelse return, 0);
        if (std.mem.eql(u8, ".total_levels.", key_name) and value.type == @intFromEnum(pdapi.JSONValueType.JSONInteger)) {
            // This must be first in Level array for the allocation to take place.
            const num_levels = value.data.intval;
            if (num_levels < 0) {
                playdate.system.logToConsole("ERROR: Invalid number of total_levels for level");
                return;
            }

            const levels_ptr: [*]*Level = @ptrCast(@alignCast(playdate.system.realloc(
                null,
                @intCast(@sizeOf(*Level) * (num_levels)),
            ) orelse unreachable));
            map.levels = levels_ptr[0..@intCast(num_levels)];

            const level_switch_ptr: [*]LevelSwitch = @ptrCast(@alignCast(playdate.system.realloc(
                null,
                @intCast(@sizeOf(*LevelSwitch) * (num_levels)),
            ) orelse unreachable));
            map.level_switches = level_switch_ptr[0..@intCast(num_levels)];
            for (map.level_switches) |*level_switch| {
                level_switch.* = LevelSwitch{};
            }
            if (debug) playdate.system.logToConsole("len of levels %d", map.levels.len);
        } else if (std.mem.eql(u8, "name", key_name) and value.type == @intFromEnum(pdapi.JSONValueType.JSONString)) {
            const name = std.mem.sliceTo(value.data.stringval, 0);
            const level = Level.init(&map_parser.game_state.bitmap_lib);
            var level_parser = Level.LevelParser{ .level = level };
            level_parser.buildLevel(.{ .file = name });
            map.levels[map_parser.added_levels] = level;
        } else if (cls != null and std.mem.eql(u8, "east", key_name) and value.type == @intFromEnum(pdapi.JSONValueType.JSONInteger)) {
            cls.?.east = @intCast(value.data.intval);
        } else if (cls != null and std.mem.eql(u8, "west", key_name) and value.type == @intFromEnum(pdapi.JSONValueType.JSONInteger)) {
            cls.?.west = @intCast(value.data.intval);
        } else if (cls != null and std.mem.eql(u8, "north", key_name) and value.type == @intFromEnum(pdapi.JSONValueType.JSONInteger)) {
            cls.?.north = @intCast(value.data.intval);
        } else if (cls != null and std.mem.eql(u8, "south", key_name) and value.type == @intFromEnum(pdapi.JSONValueType.JSONInteger)) {
            cls.?.south = @intCast(value.data.intval);
        } else if (std.mem.eql(u8, ".collision_pad.", key_name) and value.type == @intFromEnum(pdapi.JSONValueType.JSONInteger)) {
            map.collision_pad = @intCast(value.data.intval);
        } else if (std.mem.eql(u8, ".starting_level.", key_name) and value.type == @intFromEnum(pdapi.JSONValueType.JSONInteger)) {
            map.starting_level = @intCast(value.data.intval);
        } else if (std.mem.eql(u8, ".player_pos_x.", key_name) and value.type == @intFromEnum(pdapi.JSONValueType.JSONInteger)) {
            map.player_pos_x = @intCast(value.data.intval);
        } else if (std.mem.eql(u8, ".player_pos_y.", key_name) and value.type == @intFromEnum(pdapi.JSONValueType.JSONInteger)) {
            map.player_pos_y = @intCast(value.data.intval);
        }
    }

    fn didDecodeArrayValue(decoder: ?*pdapi.JSONDecoder, pos: c_int, value: pdapi.JSONValue) callconv(.C) void {
        _ = decoder;
        if (debug) playdate.system.logToConsole("didDecodeArrayValue: %d", pos);
        _ = value;
    }

    fn didDecodeSublist(decoder: ?*pdapi.JSONDecoder, name: ?[*:0]const u8, jtype: pdapi.JSONValueType) callconv(.C) ?*anyopaque {
        const map_parser: *MapParser = @ptrCast(@alignCast((decoder orelse return null).userdata));
        if (debug) playdate.system.logToConsole("didDecodeSublist: %s", name);

        const key_name = std.mem.sliceTo(name orelse return null, 0);

        if (jtype == .JSONTable and std.mem.eql(u8, "level", key_name)) {
            map_parser.current_level_switch = null;
            map_parser.added_levels += 1;
        }
        return null;
    }

    fn initDecoder(self: *MapParser) pdapi.JSONDecoder {
        return .{
            .decodeError = decodeError,
            .willDecodeSublist = willDecodeSublist,
            .shouldDecodeTableValueForKey = null,
            .didDecodeTableValue = didDecodeTableValue,
            .shouldDecodeArrayValueAtIndex = null,
            .didDecodeArrayValue = didDecodeArrayValue,
            .didDecodeSublist = didDecodeSublist,
            .userdata = self,
            .returnString = 0,
            .path = null,
        };
    }
};

pub fn buildMap(game_state: *GlobalState) void {
    const map = &game_state.map;
    game_state.state = blk: switch (game_state.map_src) {
        .string => |s| {
            var map_parser = MapParser{ .game_state = game_state };
            var json_decoder = map_parser.initDecoder();
            _ = playdate.json.decodeString(&json_decoder, s, null);
            if (map_parser.added_levels != map.levels.len)
                playdate.system.logToConsole("ERROR: Not enough maps added");
            break :blk .init_map;
        },
        .file => |f| {
            var map_reader = JsonReader.init("assets/", f) catch {
                playdate.system.logToConsole("ERROR: failed to read '%s.json' from assets", f.ptr);
                return;
            };
            defer map_reader.deinit();
            var map_parser = MapParser{ .game_state = game_state };
            var json_decoder = map_parser.initDecoder();
            _ = playdate.json.decode(&json_decoder, map_reader.json_reader, null);
            if (map_parser.added_levels != map.levels.len)
                playdate.system.logToConsole("ERROR: Not enough maps added");
            break :blk .init_map;
        },
        .http => |h| {
            const hconn = playdate.network.http.newConnection(h.host, h.port, false) orelse {
                playdate.system.logToConsole("ERROR: Failed to create connection");
                return;
            };
            playdate.network.http.setReadBufferSize(hconn, 1024 * 128);
            playdate.network.http.setUserdata(hconn, @ptrCast(game_state));
            playdate.network.http.setRequestCompleteCallback(hconn, HTTPRequestCompleteCallback);
            const err = playdate.network.http.get(hconn, h.path, null, 0);
            if (debug) playdate.system.logToConsole("http get(), err=%i", @intFromEnum(err));
            break :blk .http_wait_for_response;
        },
    };
}

fn HTTPRequestCompleteCallback(conn: ?*pdapi.HTTPConnection) callconv(.C) void {
    if (debug) playdate.system.logToConsole("Map HTTP Request Callback");

    // Must free response
    const response = http.readResponse(conn orelse return);
    defer _ = playdate.system.realloc(response.ptr, 0);

    const game_state: *GlobalState = @ptrCast(@alignCast(playdate.network.http.getUserdata(conn)));

    if (debug) playdate.system.logToConsole("About to Parse Map");
    var map_parser = MapParser{ .game_state = game_state };
    var json_decoder = map_parser.initDecoder();
    _ = playdate.json.decodeString(&json_decoder, response.ptr, null);
    if (map_parser.added_levels != game_state.map.levels.len)
        playdate.system.logToConsole("ERROR: Not enough maps added");

    game_state.state = .init_map;
    if (debug) playdate.system.logToConsole("Parsed Map");
}

const std = @import("std");
const builtin = @import("builtin");
const pdapi = @import("playdate_api_definitions.zig");

const base_types = @import("base_types.zig");
const JsonReader = base_types.JsonReader;

const http = @import("http.zig");

const GlobalState = @import("GlobalState.zig");

const Level = @import("Level.zig");

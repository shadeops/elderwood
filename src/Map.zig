const enable_debug = false;
const debug = if (builtin.mode == .Debug and enable_debug) true else false;

var global_playdate_ptr: ?*const pdapi.PlaydateAPI = null;

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

levels: []*Level = &.{},
level_switches: []LevelSwitch = &.{},
colliders: [4]*pdapi.LCDSprite = undefined, // n | e | w | s
playdate: *const pdapi.PlaydateAPI,
starting_level: usize = 0,
current_level: usize = 0,
player_pos_x: i32 = 0,
player_pos_y: i32 = 0,
collision_pad: u8 = 4,

pub fn init(playdate: *const pdapi.PlaydateAPI) *Map {
    if (global_playdate_ptr == null) {
        global_playdate_ptr = playdate;
    }

    const map_ptr: *Map = @ptrCast(@alignCast(playdate.system.realloc(null, @sizeOf(Map)) orelse unreachable));
    map_ptr.* = Map{
        .playdate = playdate,
    };
    return map_ptr;
}

pub fn deinit(self: *Map) void {
    // TODO
    for (self.levels) |level| {
        level.deinit();
    }
    _ = self.playdate.system.realloc(self.levels.ptr, 0);
    _ = self.playdate.system.realloc(self.level_switches.ptr, 0);
    self.levels = &.{};
    self.level_switches = &.{};
    for (self.colliders) |collider| {
        self.playdate.sprite.freeSprite(collider);
    }
}

pub fn buildLevelSwitches(self: *Map) void {
    const playdate = self.playdate;
    const north_south_bitmap = playdate.graphics.newBitmap(400, 4, @intFromEnum(pdapi.LCDSolidColor.ColorBlack));
    const east_west_bitmap = playdate.graphics.newBitmap(4, 240, @intFromEnum(pdapi.LCDSolidColor.ColorBlack));

    const north = playdate.sprite.newSprite() orelse unreachable;
    playdate.sprite.setImage(north, north_south_bitmap, .BitmapUnflipped);
    playdate.sprite.setCenter(north, 0, 0);
    playdate.sprite.setSize(north, 400.0, 4.0);
    playdate.sprite.setCollisionsEnabled(north, 1);
    playdate.sprite.setCollideRect(north, .{ .x = 0.0, .y = 0.0, .width = 400.0, .height = 4.0});
    playdate.sprite.setVisible(north, 0);
    const south = playdate.sprite.copy(north) orelse unreachable;
    playdate.sprite.moveTo(north, 0.0, -@as(f32, @floatFromInt(self.collision_pad)));
    playdate.sprite.moveTo(south, 0.0, @as(f32,240.0)+@as(f32,@floatFromInt(self.collision_pad)));

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
    playdate.sprite.moveTo(east, @as(f32,400.0)+@as(f32,@floatFromInt(self.collision_pad)), 0.0);
    playdate.sprite.moveTo(west, -@as(f32,@floatFromInt(self.collision_pad)), 0.0);
    
    self.colliders[@intFromEnum(CardinalDirection.east)] = east;
    self.colliders[@intFromEnum(CardinalDirection.west)] = west;

    for (&self.colliders) |collider| {
        playdate.sprite.addSprite(collider);
    }

}

pub fn setLevelTags(self: *Map, current_level: usize) void {
    if (current_level >= self.level_switches.len) return;
    const lswitch = self.level_switches[current_level];
    
    const north = self.colliders[@intFromEnum(CardinalDirection.north)];
    const south = self.colliders[@intFromEnum(CardinalDirection.south)];
    const east = self.colliders[@intFromEnum(CardinalDirection.east)];
    const west = self.colliders[@intFromEnum(CardinalDirection.west)];
    self.playdate.sprite.setTag(north, lswitch.north);
    self.playdate.sprite.setTag(south, lswitch.south);
    self.playdate.sprite.setTag(east, lswitch.east);
    self.playdate.sprite.setTag(west, lswitch.west);
}


pub const MapParser = struct {
    added_levels: usize = 0,
    current_level_switch: ?*LevelSwitch = null,

    bitlib: *const BitmapLib,
    map: *Map,

    fn decodeError(decoder: ?*pdapi.JSONDecoder, jerror: ?[*:0]const u8, linenum: c_int) callconv(.C) void {
        const jstate: *const MapParser = @ptrCast(@alignCast((decoder orelse return).userdata));
        const map = jstate.map;
        const pd = map.playdate;
        pd.system.logToConsole("ERROR: decodeError: %s %d", jerror, linenum);
    }

    fn willDecodeSublist(decoder: ?*pdapi.JSONDecoder, name: ?[*:0]const u8, jtype: pdapi.JSONValueType) callconv(.C) void {
        const jstate: *MapParser = @ptrCast(@alignCast((decoder orelse return).userdata));
        const map = jstate.map;
        const pd = map.playdate;
        if (debug) pd.system.logToConsole("[%s] willDecodeSublist: %s, [%d]", decoder.?.path, name, @intFromEnum(jtype));

        const key_name = std.mem.sliceTo(name orelse return, 0);
        
        if (jtype == .JSONTable and std.mem.eql(u8, "level", key_name)) {
            jstate.current_level_switch = &map.level_switches[jstate.added_levels];
        }
    }

    //fn shouldDecodeTableValueForKey(decoder: ?*pdapi.JSONDecoder, key: ?[*:0]const u8) callconv(.C) c_int {}

    fn didDecodeTableValue(decoder: ?*pdapi.JSONDecoder, key: ?[*:0]const u8, value: pdapi.JSONValue) callconv(.C) void {
        const jstate: *MapParser = @ptrCast(@alignCast((decoder orelse return).userdata));
        const cls = jstate.current_level_switch;
        const map = jstate.map;
        const pd = map.playdate;
        if (debug) pd.system.logToConsole("[%s] didDecodeTableValue: %s [%d]", decoder.?.path, key, value.type);

        const key_name = std.mem.sliceTo(key orelse return, 0);
        if (std.mem.eql(u8, ".total_levels.", key_name) and value.type == @intFromEnum(pdapi.JSONValueType.JSONInteger)) {
            // This must be first in Level array for the allocation to take place.
            if (value.data.intval < 0) {
                pd.system.logToConsole("ERROR: Invalid number of total_levels for level");
                return;
            }

            const levels_ptr: [*]*Level = @ptrCast(@alignCast(pd.system.realloc(
                null,
                @intCast(@sizeOf(*Level) * (value.data.intval)),
            ) orelse unreachable));
            map.levels = levels_ptr[0..@intCast(value.data.intval)];
            
            const level_switch_ptr: [*]LevelSwitch = @ptrCast(@alignCast(pd.system.realloc(
                null,
                @intCast(@sizeOf(*LevelSwitch) * (value.data.intval)),
            ) orelse unreachable));
            map.level_switches = level_switch_ptr[0..@intCast(value.data.intval)];
            for (map.level_switches) |*level_switch| {
                level_switch.* = LevelSwitch{};
            }

            if (debug) pd.system.logToConsole("len of levels %d", map.levels.len);
        } else if (std.mem.eql(u8, "name", key_name) and value.type == @intFromEnum(pdapi.JSONValueType.JSONString)) {
            const name = std.mem.sliceTo(value.data.stringval, 0);
            const level = Level.init(pd, jstate.bitlib);
            var level_parser = Level.LevelParser{ .level = level };
            level_parser.buildLevel(.{.file = name});
            map.levels[jstate.added_levels] = level;

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

    //fn shouldDecodeArrayValueAtIndex(decoder: ?*pdapi.JSONDecoder, pos: c_int) callconv(.C) c_int {}

    fn didDecodeArrayValue(decoder: ?*pdapi.JSONDecoder, pos: c_int, value: pdapi.JSONValue) callconv(.C) void {
        const jstate: *MapParser = @ptrCast(@alignCast((decoder orelse return).userdata));
        const map = jstate.map;
        const pd = map.playdate;
        if (debug) pd.system.logToConsole("didDecodeArrayValue: %d", pos);
        _ = value;
    }

    fn didDecodeSublist(decoder: ?*pdapi.JSONDecoder, name: ?[*:0]const u8, jtype: pdapi.JSONValueType) callconv(.C) ?*anyopaque {
        const jstate: *MapParser = @ptrCast(@alignCast((decoder orelse return null).userdata));
        const map = jstate.map;
        const pd = map.playdate;
        if (debug) pd.system.logToConsole("didDecodeSublist: %s", name);

        const key_name = std.mem.sliceTo(name orelse return null, 0);

        if (jtype == .JSONTable and std.mem.eql(u8, "level", key_name)) {
            jstate.current_level_switch = null;
            jstate.added_levels += 1;
        }
        return null;
    }

    pub fn buildMap(self: *MapParser, map_src: JsonSource) void {
        var json_decoder = pdapi.JSONDecoder{
            .decodeError = decodeError,
            .willDecodeSublist = willDecodeSublist,
            .shouldDecodeTableValueForKey = null, //shouldDecodeTableValueForKey,
            .didDecodeTableValue = didDecodeTableValue,
            .shouldDecodeArrayValueAtIndex = null, //shouldDecodeArrayValueAtIndex,
            .didDecodeArrayValue = didDecodeArrayValue,
            .didDecodeSublist = didDecodeSublist,
            .userdata = self,
            .returnString = 0,
            .path = null,
        };

        switch (map_src) {
            .string => |s| _ = self.map.playdate.json.decodeString(&json_decoder, s, null),
            .file => |f| {
                var map_reader = JsonReader.init(self.map.playdate, "assets/", f) catch {
                    self.map.playdate.system.logToConsole("ERROR: failed to build map");
                    return;
                };
                defer map_reader.deinit();
                 _ = self.map.playdate.json.decode(&json_decoder, map_reader.json_reader, null);
            },
        }

        if (self.added_levels != self.map.levels.len)
            self.map.playdate.system.logToConsole("ERROR: Not enough maps added");
        if (debug) {
            for (self.map.levels, 0..) |level, i| {
                self.map.playdate.system.logToConsole("Level: %d has %d sprites", i, level.sprites.len);
            }
        }
    }
};

const std = @import("std");
const builtin = @import("builtin");
const pdapi = @import("playdate_api_definitions.zig");

const BitmapLib = @import("BitmapLib.zig");
const base_types = @import("base_types.zig");

const Position = base_types.Position;
const JsonSource = base_types.JsonSource;
const JsonReader = base_types.JsonReader;

const Level = @import("Level.zig");

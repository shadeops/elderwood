const enable_debug = false;
const debug = if (builtin.mode == .Debug and enable_debug) true else false;

// This is incredibly annoying. The majority of functions allow you to pass around
// userData so various data and the Playdate API can be passed around. However for
// the sprite update functions to fetch the userData or any other info requires
// the Playdate API and the only way to fetch that is through a global annoyingly.
// To work around this, in the Level.init, we'll set the ptr if it is null
var global_playdate_ptr: ?*const pdapi.PlaydateAPI = null;

const Level = @This();

sprites: []*pdapi.LCDSprite,
// TODO: Given that we have to have a global playdate pointer, we can probably remove this
playdate: *const pdapi.PlaydateAPI,
bitlib: *const BitmapLib,

pub fn init(playdate: *const pdapi.PlaydateAPI, bitmap_lib: *const BitmapLib) *Level {
    if (global_playdate_ptr == null) {
        global_playdate_ptr = playdate;
    }

    const level_ptr: *Level = @ptrCast(@alignCast(playdate.system.realloc(
        null,
        @sizeOf(Level)
    ) orelse unreachable));
    level_ptr.* = Level{
        .sprites = undefined,
        .playdate = playdate,
        .bitlib = bitmap_lib,
    };
    return level_ptr;
}

pub fn deinit(self: *Level) void {
    self.playdate.sprite.removeSprites(self.sprites.ptr, self.sprites.len);
    for (self.sprites) |sprite| {
        const userdata_ptr = self.playdate.sprite.getUserdata(sprite);
        _ = self.playdate.system.realloc(userdata_ptr, 0);
        self.playdate.sprite.freeSprite(sprite);
    }
    self.sprites.len = 0;
    _ = self.playdate.system.realloc(self.sprites.ptr, 0);
}

pub fn populate(self: *const Level) void {
    for (self.sprites) |sprite| {
        self.playdate.sprite.addSprite(sprite);
    }
}

const LoopingSprite = struct {
    id: i16,
    duration: i16,
    frame_offset: i16,
    bitlib: *const BitmapLib,

    fn loopAnimation(sprite: ?*pdapi.LCDSprite) callconv(.C) void {
        const playdate = global_playdate_ptr orelse return;
        const userdata = playdate.sprite.getUserdata(sprite) orelse return;
        const loop_state: *LoopingSprite = @ptrCast(@alignCast(userdata));
        loop_state.frame_offset = @rem(loop_state.frame_offset + 1, loop_state.duration);
        playdate.sprite.setImage(
            sprite,
            loop_state.bitlib.bitmaps[@intCast(loop_state.id + loop_state.frame_offset)],
            playdate.sprite.getImageFlip(sprite),
        );
    }
};

const SpritePlacement = struct {
    id: i16 = -1,
    depth: i16 = 0,
    pos: Position = .{},
    frame_offset: i16 = 0,
    duration: i16 = 1,
    flip: bool = false,
    animated: bool = false,
};

pub const LevelParser = struct {
    in_position: bool = false,
    sprite_placement: SpritePlacement = .{},
    level: *Level,
    added_sprites: usize = 0, 

    fn decodeError(decoder: ?*pdapi.JSONDecoder, jerror: ?[*:0]const u8, linenum: c_int) callconv(.C) void {
        const jstate: *const LevelParser = @ptrCast(@alignCast((decoder orelse return).userdata));
        const level = jstate.level;
        const pd = level.playdate;
        pd.system.logToConsole("ERROR: decodeError: %s %d", jerror, linenum);
    }

    fn willDecodeSublist(decoder: ?*pdapi.JSONDecoder, name: ?[*:0]const u8, jtype: pdapi.JSONValueType) callconv(.C) void {
        const jstate: *LevelParser = @ptrCast(@alignCast((decoder orelse return).userdata));
        const level = jstate.level;
        const pd = level.playdate;

        if (jtype == .JSONArray and std.mem.eql(u8, "position", std.mem.sliceTo(name.?, 0))) {
            jstate.in_position = true;
        }
        if (debug) pd.system.logToConsole("[%s] willDecodeSublist: %s, [%d]", decoder.?.path, name, @intFromEnum(jtype));
    }

    //fn shouldDecodeTableValueForKey(decoder: ?*pdapi.JSONDecoder, key: ?[*:0]const u8) callconv(.C) c_int {}

    fn didDecodeTableValue(decoder: ?*pdapi.JSONDecoder, key: ?[*:0]const u8, value: pdapi.JSONValue) callconv(.C) void {
        const jstate: *LevelParser = @ptrCast(@alignCast((decoder orelse return).userdata));
        const level = jstate.level;
        const pd = level.playdate;

        const key_name = std.mem.sliceTo(key orelse return, 0);
        if (std.mem.eql(u8, ".total_sprites.", key_name) and value.type == @intFromEnum(pdapi.JSONValueType.JSONInteger)) {
            // This must be first in Level array for the allocation to take place.
            if (value.data.intval < 0) {
                pd.system.logToConsole("ERROR: Invalid number of total_sprites for level");
                return;
            }
            const sprites_ptr: [*]*pdapi.LCDSprite = @ptrCast(@alignCast(pd.system.realloc(
                null,
                @intCast(@sizeOf(*pdapi.LCDSprite) * (value.data.intval)),
            ) orelse unreachable));
            level.sprites = sprites_ptr[0..@intCast(value.data.intval)];
            if (debug) pd.system.logToConsole("len of sprites %d", level.sprites.len);
        } else if (std.mem.eql(u8, "bitmap_id", key_name) and value.type == @intFromEnum(pdapi.JSONValueType.JSONInteger)) {
            jstate.sprite_placement.id = @intCast(value.data.intval);
        } else if (std.mem.eql(u8, "depth", key_name) and value.type == @intFromEnum(pdapi.JSONValueType.JSONInteger)) {
            jstate.sprite_placement.depth = @intCast(value.data.intval);
        } else if (std.mem.eql(u8, "frame_offset", key_name) and value.type == @intFromEnum(pdapi.JSONValueType.JSONInteger)) {
            jstate.sprite_placement.frame_offset = @intCast(value.data.intval);
        } else if (std.mem.eql(u8, "flip", key_name)) {
            jstate.sprite_placement.flip = (value.type == @intFromEnum(pdapi.JSONValueType.JSONTrue));
        } else if (std.mem.eql(u8, "animated", key_name)) {
            jstate.sprite_placement.animated = (value.type == @intFromEnum(pdapi.JSONValueType.JSONTrue));
        } else if (std.mem.eql(u8, "duration", key_name) and value.type == @intFromEnum(pdapi.JSONValueType.JSONInteger)) {
            jstate.sprite_placement.duration = @intCast(value.data.intval);
        }
        if (debug) pd.system.logToConsole("[%s] didDecodeTableValue: %s [%d]", decoder.?.path, key, value.type);
    }

    //fn shouldDecodeArrayValueAtIndex(decoder: ?*pdapi.JSONDecoder, pos: c_int) callconv(.C) c_int {}

    fn didDecodeArrayValue(decoder: ?*pdapi.JSONDecoder, pos: c_int, value: pdapi.JSONValue) callconv(.C) void {
        const jstate: *LevelParser = @ptrCast(@alignCast((decoder orelse return).userdata));
        const level = jstate.level;
        const pd = level.playdate;
        if (jstate.in_position and value.type == @intFromEnum(pdapi.JSONValueType.JSONInteger)) {
            switch (pos) {
                1 => jstate.sprite_placement.pos.x = @truncate(value.data.intval),
                2 => jstate.sprite_placement.pos.y = @truncate(value.data.intval),
                else => return,
            }
        }
        if (debug) pd.system.logToConsole("didDecodeArrayValue: %d", pos);
    }

    fn didDecodeSublist(decoder: ?*pdapi.JSONDecoder, name: ?[*:0]const u8, jtype: pdapi.JSONValueType) callconv(.C) ?*anyopaque {
        _ = jtype;
        const jstate: *LevelParser = @ptrCast(@alignCast((decoder orelse return null).userdata));
        const level = jstate.level;
        const pd = level.playdate;
        const key_name = std.mem.sliceTo(name orelse return null, 0);
        if (std.mem.eql(u8, "sprite", key_name)) {
            jstate.createSprite(jstate.sprite_placement) catch {
                pd.system.logToConsole("ERROR: Unable to add sprite, Level full");
                return null;
            };
        } else if (std.mem.eql(u8, "position", key_name)) {
            jstate.in_position = false;
        }

        if (debug) pd.system.logToConsole("didDecodeSublist: %s", name);
        return null;
    }

    fn createSprite(self: *LevelParser, placement: SpritePlacement) error{LevelFull}!void {
        if (self.added_sprites+1 > self.level.sprites.len) return error.LevelFull;
        const pd = self.level.playdate;
        const sprite = pd.sprite.newSprite() orelse unreachable;
        const id = placement.id;
        if (id < 0 or id >= self.level.bitlib.bitmaps.len) {
            pd.system.logToConsole("ERROR: Invalid bitmap_id %d, len: %d", id, self.level.bitlib.bitmaps.len);
            return;
        }
        const bitmap = self.level.bitlib.bitmaps[@intCast(id)];
        var img_width: c_int = 0;
        var img_height: c_int = 0;
        pd.graphics.getBitmapData(bitmap, &img_width, &img_height, null, null, null);
        pd.sprite.setImage(sprite, bitmap, .BitmapUnflipped);

        // This is required since the flipped arg of setImage doesn't seem to work.
        pd.sprite.setImageFlip(sprite, if (placement.flip) .BitmapFlippedXY else .BitmapFlippedY);
        pd.sprite.setCenter(sprite, 0.0, 0.0);
        pd.sprite.moveTo(sprite, @floatFromInt(placement.pos.x), @floatFromInt(placement.pos.y));
        pd.sprite.setSize(sprite, @floatFromInt(img_width), @floatFromInt(img_height));
        pd.sprite.setZIndex(sprite, placement.depth);
        if (placement.animated) {
            // TODO check return ptr
            const loop_state: *LoopingSprite = @ptrCast(@alignCast(pd.system.realloc(null, @sizeOf(LoopingSprite))));
            loop_state.* = .{
                .id = placement.id,
                .duration = placement.duration,
                .frame_offset = placement.frame_offset,
                .bitlib = self.level.bitlib,
            };
            pd.sprite.setUserdata(sprite, @ptrCast(loop_state));
            pd.sprite.setUpdateFunction(sprite, LoopingSprite.loopAnimation);
        }
        self.added_sprites += 1;
        self.level.sprites[self.added_sprites - 1] = sprite;
    }


    pub fn buildLevel(self: *LevelParser) void {
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
        if (debug) self.level.playdate.system.logToConsole("Json Size: %d\n", level_json.len);
        _ = self.level.playdate.json.decodeString(&json_decoder, level_json, null);
    }
};

const std = @import("std");
const builtin = @import("builtin");
const pdapi = @import("playdate_api_definitions.zig");

const BitmapLib = @import("BitmapLib.zig");
const base_types = @import("base_types.zig");
const Position = base_types.Position;

const level_json = @embedFile("level.json");

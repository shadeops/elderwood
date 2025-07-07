const std = @import("std");
const builtin = @import("builtin");
const pdapi = @import("playdate_api_definitions.zig");

const BitmapLib = @import("BitmapLib.zig");
const base_types = @import("base_types.zig");
const Position = base_types.Position;

const level_json = @embedFile("level.json");

const enable_debug = false;
const debug = if (builtin.mode == .Debug and enable_debug) true else false;

// This is incredibly annoying. The majority of functions allow you to pass around
// userData so various data and the Playdate API can be passed around. However for
// the sprite update functions to fetch the userData or any other info requires
// the Playdate API and the only way to fetch that is through a global annoyingly.
// To work around this, in the Level.init, we'll set the ptr if it is null
var global_playdate_ptr: ?*const pdapi.PlaydateAPI = null;

const Level = @This();
const max_sprites = 128;

sprites: []*pdapi.LCDSprite,
// TODO: Given that we have to have a global playdate pointer, we can probably remove this
playdate: *const pdapi.PlaydateAPI,
bitmap_lib: BitmapLib,

// TODO, bitmap_lib might make more sense to pass to the parser and not live with the
//       Level
pub fn init(playdate: *const pdapi.PlaydateAPI, bitmap_lib: BitmapLib) Level {
    if (global_playdate_ptr == null) {
        global_playdate_ptr = playdate;
    }

    const sprites_ptr: [*]*pdapi.LCDSprite = @ptrCast(@alignCast(playdate.system.realloc(
        null,
        @sizeOf(*pdapi.LCDSprite) * max_sprites,
    ) orelse unreachable));
    var level = Level{
        .sprites = sprites_ptr[0..max_sprites],
        .playdate = playdate,
        .bitmap_lib = bitmap_lib,
    };
    if (debug) playdate.system.logToConsole("len of sprites %d", level.sprites.len);
    level.sprites.len = 0;
    return level;
}

pub fn deinit(self: *Level) void {
    for (self.sprites) |sprite| {
        self.playdate.graphics.freeSprite(sprite);
    }
    self.sprites.len = 0;
    _ = self.playdate.system.realloc(self.sprites.ptr, 0);
}

fn createSprite(self: *Level, placement: SpritePlacement) error{LevelFull}!void {
    if (self.sprites.len + 1 >= max_sprites) return error.LevelFull;
    const pd = self.playdate;
    const sprite = pd.sprite.newSprite() orelse unreachable;
    const id = placement.id;
    if (id < 0 or id >= self.bitmap_lib.bitmaps.len) {
        pd.system.logToConsole("ERROR: Invalid bitmap_id %d, len: %d", id, self.bitmap_lib.bitmaps.len);
        return;
    }
    const bitmap = self.bitmap_lib.bitmaps[@intCast(id)];
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
            .bitmap_lib = self.bitmap_lib,
        };
        pd.sprite.setUserdata(sprite, @ptrCast(loop_state));
        pd.sprite.setUpdateFunction(sprite, LoopingSprite.loopAnimation);
    }
    self.sprites.len += 1;
    self.sprites[self.sprites.len - 1] = sprite;
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
    bitmap_lib: BitmapLib,

    fn loopAnimation(sprite: ?*pdapi.LCDSprite) callconv(.C) void {
        const playdate = global_playdate_ptr orelse return;
        const userdata = playdate.sprite.getUserdata(sprite) orelse return;
        const loop_state: *LoopingSprite = @ptrCast(@alignCast(userdata));
        loop_state.frame_offset = @rem(loop_state.frame_offset + 1, loop_state.duration);
        playdate.sprite.setImage(
            sprite,
            loop_state.bitmap_lib.bitmaps[@intCast(loop_state.id + loop_state.frame_offset)],
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
    in_sprite: bool = false,
    sprite_placement: SpritePlacement = .{},
    level: *Level,

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

        if (jtype == .JSONTable and std.mem.eql(u8, "sprite", std.mem.sliceTo(name.?, 0))) {
            jstate.in_sprite = true;
        }
        if (debug) pd.system.logToConsole("[%s] willDecodeSublist: %s, [%d]", decoder.?.path, name, @intFromEnum(jtype));
    }

    //fn shouldDecodeTableValueForKey(decoder: ?*pdapi.JSONDecoder, key: ?[*:0]const u8) callconv(.C) c_int {}

    fn didDecodeTableValue(decoder: ?*pdapi.JSONDecoder, key: ?[*:0]const u8, value: pdapi.JSONValue) callconv(.C) void {
        const jstate: *LevelParser = @ptrCast(@alignCast((decoder orelse return).userdata));
        const level = jstate.level;
        const pd = level.playdate;

        const key_name = std.mem.sliceTo(key orelse return, 0);
        if (jstate.in_sprite) {
            if (std.mem.eql(u8, "bitmap_id", key_name) and value.type == @intFromEnum(pdapi.JSONValueType.JSONInteger)) {
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
        }
        if (debug) pd.system.logToConsole("[%s] didDecodeTableValue: %s [%d]", decoder.?.path, key, value.type);
    }

    //fn shouldDecodeArrayValueAtIndex(decoder: ?*pdapi.JSONDecoder, pos: c_int) callconv(.C) c_int {}

    fn didDecodeArrayValue(decoder: ?*pdapi.JSONDecoder, pos: c_int, value: pdapi.JSONValue) callconv(.C) void {
        const jstate: *LevelParser = @ptrCast(@alignCast((decoder orelse return).userdata));
        const level = jstate.level;
        const pd = level.playdate;
        if (jstate.in_sprite and value.type == @intFromEnum(pdapi.JSONValueType.JSONInteger)) {
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
            level.createSprite(jstate.sprite_placement) catch {
                pd.system.logToConsole("ERROR: Unable to add sprite, Level full");
                return null;
            };
            jstate.in_sprite = false;
        }

        if (debug) pd.system.logToConsole("didDecodeSublist: %s", name);
        return null;
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

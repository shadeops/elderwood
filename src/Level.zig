const enable_debug = false;
const debug = if (builtin.mode == .Debug and enable_debug) true else false;

const playdate = @import("PDapi.zig");

const Level = @This();

colliders: []*pdapi.LCDSprite = &.{},
sprites: []*pdapi.LCDSprite = &.{},

bitlib: *const BitmapLib,
name: [32:0]u8 = @splat(0),

loaded: bool,

pub fn init(map_name: []const u8, bitmap_lib: *const BitmapLib) *Level {
    const level_ptr: *Level = @ptrCast(@alignCast(playdate.system.realloc(null, @sizeOf(Level)) orelse unreachable));
    level_ptr.* = Level{
        .bitlib = bitmap_lib,
        .loaded = false,
    };
    std.mem.copyForwards(u8, &level_ptr.name, map_name);
    return level_ptr;
}

pub fn deinit(self: *Level) void {
    self.reset();
    self.name = @splat(0);
}

pub fn populate(self: *const Level) void {
    for (self.sprites) |sprite| {
        playdate.sprite.addSprite(sprite);
    }
    for (self.colliders) |collider| {
        playdate.sprite.addSprite(collider);
    }
}

pub fn reset(self: *Level) void {
    self.loaded = false;
    self.clear();
    //playdate.sprite.removeSprites(self.sprites.ptr, self.sprites.len);
    for (self.sprites) |sprite| {
        const userdata_ptr = playdate.sprite.getUserdata(sprite);
        if (userdata_ptr) |userdata| _ = playdate.system.realloc(userdata, 0);
        playdate.sprite.freeSprite(sprite);
    }
    //playdate.sprite.removeSprites(self.colliders.ptr, self.colliders.len);
    for (self.colliders) |sprite| {
        const bitmap = playdate.sprite.getImage(sprite);
        playdate.graphics.freeBitmap(bitmap);
        playdate.sprite.freeSprite(sprite);
    }
    _ = playdate.system.realloc(@ptrCast(@alignCast(self.sprites.ptr)), 0);
    _ = playdate.system.realloc(@ptrCast(@alignCast(self.colliders.ptr)), 0);
    self.sprites = &.{};
    self.colliders = &.{};
}

pub fn clear(self: *const Level) void {
    playdate.sprite.removeSprites(@ptrCast(self.sprites.ptr), @intCast(self.sprites.len));
    playdate.sprite.removeSprites(@ptrCast(self.colliders.ptr), @intCast(self.colliders.len));
}

const LoopingSprite = struct {
    id: i16,
    duration: i16,
    frame_offset: i16,
    bitlib: *const BitmapLib,

    fn loopAnimation(sprite: ?*pdapi.LCDSprite) callconv(.C) void {
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

const SpriteType = enum {
    sprite,
    collider,
    none,
};

const ColliderType = enum {
    blocker,
    level_switch,
};

const ColliderPlacement = struct {
    pos: Position = .{},
    resx: c_int = 0,
    resy: c_int = 0,
    ctype: ColliderType = .blocker,
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

const ParsedSprite = union(SpriteType) {
    sprite: SpritePlacement,
    collider: ColliderPlacement,
    none: void,
};

pub const LevelParser = struct {
    level: *Level,
    game_state: *GlobalState,
    in_position: bool = false,
    parsed_sprite: ParsedSprite = .{ .none = {} },
    added_sprites: usize = 0,
    added_colliders: usize = 0,

    fn decodeError(decoder: ?*pdapi.JSONDecoder, jerror: ?[*:0]const u8, linenum: c_int) callconv(.C) void {
        _ = decoder;
        playdate.system.logToConsole("ERROR: decodeError: %s %d", jerror, linenum);
    }

    fn willDecodeSublist(decoder: ?*pdapi.JSONDecoder, name: ?[*:0]const u8, jtype: pdapi.JSONValueType) callconv(.C) void {
        const jstate: *LevelParser = @ptrCast(@alignCast((decoder orelse return).userdata));
        if (debug) playdate.system.logToConsole("[%s] willDecodeSublist: %s, [%d]", decoder.?.path, name, @intFromEnum(jtype));

        const key_name = std.mem.sliceTo(name orelse return, 0);
        if (jtype == .JSONArray and std.mem.eql(u8, "position", key_name)) {
            jstate.in_position = true;
        } else if (jtype == .JSONTable and std.mem.eql(u8, "sprite", key_name)) {
            jstate.parsed_sprite = .{ .sprite = .{} };
        } else if (jtype == .JSONTable and std.mem.eql(u8, "collider", key_name)) {
            jstate.parsed_sprite = .{ .collider = .{} };
        }
    }

    fn didDecodeTableValue(decoder: ?*pdapi.JSONDecoder, key: ?[*:0]const u8, value: pdapi.JSONValue) callconv(.C) void {
        const jstate: *LevelParser = @ptrCast(@alignCast((decoder orelse return).userdata));
        const level = jstate.level;
        if (debug) playdate.system.logToConsole("[%s] didDecodeTableValue: %s [%d]", decoder.?.path, key, value.type);

        const key_name = std.mem.sliceTo(key orelse return, 0);
        if (std.mem.eql(u8, ".total_sprites.", key_name) and value.type == @intFromEnum(pdapi.JSONValueType.JSONInteger)) {
            // This must be first in Level array for the allocation to take place.
            if (value.data.intval < 0) {
                playdate.system.logToConsole("ERROR: Invalid number of total_sprites for level");
                return;
            }
            const sprites_ptr: [*]*pdapi.LCDSprite = @ptrCast(@alignCast(playdate.system.realloc(
                null,
                @intCast(@sizeOf(*pdapi.LCDSprite) * (value.data.intval)),
            ) orelse unreachable));
            level.sprites = sprites_ptr[0..@intCast(value.data.intval)];
            if (debug) playdate.system.logToConsole("len of sprites %d", level.sprites.len);
        } else if (std.mem.eql(u8, ".total_colliders.", key_name) and value.type == @intFromEnum(pdapi.JSONValueType.JSONInteger)) {
            // This must be first in Level array for the allocation to take place.
            if (value.data.intval < 0) {
                playdate.system.logToConsole("ERROR: Invalid number of total_sprites for level");
                return;
            }
            const colliders_ptr: [*]*pdapi.LCDSprite = @ptrCast(@alignCast(playdate.system.realloc(
                null,
                @intCast(@sizeOf(*pdapi.LCDSprite) * (value.data.intval)),
            ) orelse unreachable));
            level.colliders = colliders_ptr[0..@intCast(value.data.intval)];
            if (debug) playdate.system.logToConsole("len of sprites %d", level.sprites.len);
        } else if (std.mem.eql(u8, ".level_name.", key_name) and value.type == @intFromEnum(pdapi.JSONValueType.JSONString)) {
            const name = std.mem.sliceTo(value.data.stringval, 0);
            if (name.len > level.name.len) {
                playdate.system.logToConsole("ERROR: %s name too long", value.data.stringval);
                return;
            }
            std.mem.copyForwards(u8, &level.name, name);
        } else {
            switch (jstate.parsed_sprite) {
                .sprite => |*s| {
                    if (std.mem.eql(u8, "bitmap_id", key_name) and value.type == @intFromEnum(pdapi.JSONValueType.JSONInteger)) {
                        s.id = @intCast(value.data.intval);
                    } else if (std.mem.eql(u8, "depth", key_name) and value.type == @intFromEnum(pdapi.JSONValueType.JSONInteger)) {
                        s.depth = @intCast(value.data.intval);
                    } else if (std.mem.eql(u8, "frame_offset", key_name) and value.type == @intFromEnum(pdapi.JSONValueType.JSONInteger)) {
                        s.frame_offset = @intCast(value.data.intval);
                    } else if (std.mem.eql(u8, "flip", key_name)) {
                        s.flip = (value.type == @intFromEnum(pdapi.JSONValueType.JSONTrue));
                    } else if (std.mem.eql(u8, "animated", key_name)) {
                        s.animated = (value.type == @intFromEnum(pdapi.JSONValueType.JSONTrue));
                    } else if (std.mem.eql(u8, "duration", key_name) and value.type == @intFromEnum(pdapi.JSONValueType.JSONInteger)) {
                        s.duration = @intCast(value.data.intval);
                    }
                },
                .collider => |*c| {
                    if (std.mem.eql(u8, "resx", key_name) and value.type == @intFromEnum(pdapi.JSONValueType.JSONInteger)) {
                        c.resx = @intCast(value.data.intval);
                    } else if (std.mem.eql(u8, "resy", key_name) and value.type == @intFromEnum(pdapi.JSONValueType.JSONInteger)) {
                        c.resy = @intCast(value.data.intval);
                    }
                },
                .none => return,
            }
        }
    }

    fn didDecodeArrayValue(decoder: ?*pdapi.JSONDecoder, pos: c_int, value: pdapi.JSONValue) callconv(.C) void {
        const jstate: *LevelParser = @ptrCast(@alignCast((decoder orelse return).userdata));
        if (debug) playdate.system.logToConsole("didDecodeArrayValue: %d", pos);
        if (jstate.in_position and value.type == @intFromEnum(pdapi.JSONValueType.JSONInteger)) {
            switch (pos) {
                //1 => jstate.sprite_placement.pos.x = @truncate(value.data.intval),
                //2 => jstate.sprite_placement.pos.y = @truncate(value.data.intval),
                1 => switch (jstate.parsed_sprite) {
                    .none => return,
                    inline else => |*s| s.pos.x = @truncate(value.data.intval),
                },
                2 => switch (jstate.parsed_sprite) {
                    .none => return,
                    inline else => |*s| s.pos.y = @truncate(value.data.intval),
                },
                else => return,
            }
        }
    }

    fn didDecodeSublist(decoder: ?*pdapi.JSONDecoder, name: ?[*:0]const u8, jtype: pdapi.JSONValueType) callconv(.C) ?*anyopaque {
        _ = jtype;
        const jstate: *LevelParser = @ptrCast(@alignCast((decoder orelse return null).userdata));
        if (debug) playdate.system.logToConsole("didDecodeSublist: %s", name);

        const key_name = std.mem.sliceTo(name orelse return null, 0);
        if (std.mem.eql(u8, "sprite", key_name)) {
            switch (jstate.parsed_sprite) {
                .sprite => |s| {
                    jstate.createSprite(s) catch {
                        playdate.system.logToConsole("ERROR: Unable to add sprite, Level full");
                        return null;
                    };
                    jstate.parsed_sprite = .{ .none = {} };
                },
                else => return null,
            }
        } else if (std.mem.eql(u8, "collider", key_name)) {
            switch (jstate.parsed_sprite) {
                .collider => |c| {
                    jstate.createCollider(c) catch {
                        playdate.system.logToConsole("ERROR: Unable to add sprite, Level full");
                        return null;
                    };
                    jstate.parsed_sprite = .{ .none = {} };
                },
                else => return null,
            }
        } else if (std.mem.eql(u8, "position", key_name)) {
            jstate.in_position = false;
        }
        return null;
    }

    fn createSprite(self: *LevelParser, placement: SpritePlacement) error{LevelFull}!void {
        if (self.added_sprites + 1 > self.level.sprites.len) return error.LevelFull;
        if (debug) playdate.system.logToConsole("Creating Sprite");

        const sprite = playdate.sprite.newSprite() orelse unreachable;
        const id = placement.id;
        if (id < 0 or id >= self.level.bitlib.bitmaps.len) {
            playdate.system.logToConsole("ERROR: Invalid bitmap_id %d, len: %d", id, self.level.bitlib.bitmaps.len);
            return;
        }
        // TODO
        //loop_state.frame_offset = @rem(loop_state.frame_offset + 1, loop_state.duration);
        const offset: usize = if (placement.animated) @intCast(@mod(placement.frame_offset, placement.duration)) else 0;
        const bitmap = self.level.bitlib.bitmaps[@as(usize, @intCast(id)) + offset];
        var img_width: c_int = 0;
        var img_height: c_int = 0;
        playdate.graphics.getBitmapData(bitmap, &img_width, &img_height, null, null, null);
        playdate.sprite.setImage(sprite, bitmap, .BitmapUnflipped);

        // This is required since the flipped arg of setImage doesn't seem to work.
        playdate.sprite.setImageFlip(sprite, if (placement.flip) .BitmapFlippedXY else .BitmapFlippedY);
        playdate.sprite.setCenter(sprite, 0.0, 0.0);
        playdate.sprite.moveTo(sprite, @floatFromInt(placement.pos.x), @floatFromInt(placement.pos.y));
        playdate.sprite.setSize(sprite, @floatFromInt(img_width), @floatFromInt(img_height));
        playdate.sprite.setZIndex(sprite, placement.depth);
        if (placement.animated) {
            // TODO check return ptr
            const loop_state: *LoopingSprite = @ptrCast(@alignCast(playdate.system.realloc(null, @sizeOf(LoopingSprite))));
            loop_state.* = .{
                .id = placement.id,
                .duration = placement.duration,
                .frame_offset = placement.frame_offset,
                .bitlib = self.level.bitlib,
            };
            playdate.sprite.setUserdata(sprite, @ptrCast(loop_state));
            playdate.sprite.setUpdateFunction(sprite, LoopingSprite.loopAnimation);
        }
        self.added_sprites += 1;
        self.level.sprites[self.added_sprites - 1] = sprite;
    }

    fn createCollider(self: *LevelParser, collider: ColliderPlacement) error{LevelFull}!void {
        if (self.added_colliders + 1 > self.level.colliders.len) return error.LevelFull;
        if (debug) playdate.system.logToConsole("Creating Collider");

        const bitmap = playdate.graphics.newBitmap(collider.resx, collider.resy, @intFromEnum(pdapi.LCDSolidColor.ColorBlack));
        const sprite = playdate.sprite.newSprite() orelse unreachable;
        playdate.sprite.setImage(sprite, bitmap, .BitmapUnflipped);
        playdate.sprite.setCenter(sprite, 0, 0);
        playdate.sprite.setSize(sprite, @floatFromInt(collider.resx), @floatFromInt(collider.resy));
        playdate.sprite.moveTo(sprite, @floatFromInt(collider.pos.x), @floatFromInt(collider.pos.y));
        playdate.sprite.setCollisionsEnabled(sprite, 1);
        playdate.sprite.setCollideRect(sprite, .{
            .x = 0.0,
            .y = 0.0,
            .width = @floatFromInt(collider.resx),
            .height = @floatFromInt(collider.resy),
        });
        playdate.sprite.setVisible(sprite, 0);
        self.added_colliders += 1;
        self.level.colliders[self.added_colliders - 1] = sprite;
    }

    fn initDecoder(self: *LevelParser) pdapi.JSONDecoder {
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

pub fn buildLevel(self: *Level, game_state: *GlobalState) void {
    // rethink this. We want to set this to be true so that the build levels state
    // doesn't try to reload this level
    defer self.loaded = true;
    if (debug) playdate.system.logToConsole("Loading Level %s", &self.name);
    game_state.state = blk: switch (game_state.level_src) {
        .string => |s| {
            var level_parser = LevelParser{ .level = self, .game_state = game_state };
            var json_decoder = level_parser.initDecoder();
            _ = playdate.json.decodeString(&json_decoder, s, null);
            break :blk .build_levels;
        },
        .file => |f| {
            var level_src = f;
            level_src.name = std.mem.sliceTo(&self.name, 0);
            var level_reader = JsonReader.init(level_src) catch {
                playdate.system.logToConsole("wtf");
                playdate.system.logToConsole(
                    "ERROR: failed to read '%s%s' from %s",
                    level_src.name.ptr,
                    level_src.ext.ptr,
                    level_src.path.ptr,
                );
                return;
            };
            defer level_reader.deinit();
            var level_parser = LevelParser{ .level = self, .game_state = game_state };
            var json_decoder = level_parser.initDecoder();
            _ = playdate.json.decode(&json_decoder, level_reader.json_reader, null);
            break :blk .build_levels;
        },
        .http => |h| {
            const hconn = playdate.network.http.newConnection(h.host, h.port, false) orelse {
                playdate.system.logToConsole("ERROR: Failed to create connection");
                return;
            };
            playdate.network.http.setReadBufferSize(hconn, 1024 * 128);

            const level_parser: *LevelParser = @ptrCast(@alignCast(playdate.system.realloc(null, @sizeOf(LevelParser))));
            level_parser.* = .{
                .level = self,
                .game_state = game_state,
            };

            playdate.network.http.setUserdata(hconn, @ptrCast(level_parser));
            playdate.network.http.setRequestCompleteCallback(hconn, HTTPRequestCompleteCallback);
            var level_src = h;
            level_src.name = std.mem.sliceTo(&self.name, 0);
            var buf: [64:0]u8 = @splat(0);
            const path = level_src.getPath(&buf);
            const err = playdate.network.http.get(hconn, path, null, 0);
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

    const level_parser: *LevelParser = @ptrCast(@alignCast(playdate.network.http.getUserdata(conn)));
    defer _ = playdate.system.realloc(@ptrCast(level_parser), 0);

    if (debug) playdate.system.logToConsole("About to Parse Level");
    var json_decoder = level_parser.initDecoder();
    _ = playdate.json.decodeString(&json_decoder, response.ptr, null);

    level_parser.game_state.state = .build_levels;
    if (debug) playdate.system.logToConsole("Parsed Level");
}

const std = @import("std");
const builtin = @import("builtin");
const pdapi = @import("playdate_api_definitions.zig");

const BitmapLib = @import("BitmapLib.zig");
const base_types = @import("base_types.zig");
const JsonReader = base_types.JsonReader;

const http = @import("http.zig");
const GlobalState = @import("GlobalState.zig");

const Position = base_types.Position;

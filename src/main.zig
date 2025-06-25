const std = @import("std");
const builtin = @import("builtin");
const pdapi = @import("playdate_api_definitions.zig");
const panic_handler = @import("panic_handler.zig");

const library = @embedFile("library.json");
const debug = builtin.mode == .Debug;

pub const panic = panic_handler.panic;

const GlobalState = struct {
    playdate: *pdapi.PlaydateAPI,
    pos: Position,
    bitlib: BitmapLib,
    level: Level,
    frame: u8,
    flipped: bool,
};

const Position = struct {
    x: i16,
    y: i16,
};

const Level = struct {
    const max_sprites = 128;

    sprites: []*pdapi.LCDSprite,

    fn init(playdate: *const pdapi.PlaydateAPI) Level {
        const sprites_ptr: [*]*pdapi.LCDSprite = @ptrCast(@alignCast(playdate.system.realloc(
            null,
            @sizeOf(*pdapi.LCDSprite) * max_sprites,
        ) orelse unreachable));
        var level = Level{
            .sprites = sprites_ptr[0..max_sprites],
        };
        if (debug) playdate.system.logToConsole("len of sprites %d", level.sprites.len);
        level.sprites.len = 0;
        return level;
    }

    fn deinit(self: *Level, playdate: *const pdapi.PlaydateAPI) void {
        for (self.sprites) |sprite| {
            playdate.graphics.freeSprite(sprite);
        }
        self.sprites.len = 0;
    }

    fn addSprite(self: *Level, sprite: *pdapi.LCDSprite) error{LevelFull}!void {
        if (self.sprites.len + 1 >= max_sprites) return error.LevelFull;
        self.sprites.len += 1;
        self.sprites[self.sprites.len - 1] = sprite;
    }
};

const BitmapLib = struct {
    const max_bitmaps = 128;

    bitmaps: []*pdapi.LCDBitmap,
    playdate: *const pdapi.PlaydateAPI,

    fn init(playdate: *const pdapi.PlaydateAPI) BitmapLib {
        const bitmaps_ptr: [*]*pdapi.LCDBitmap = @ptrCast(@alignCast(playdate.system.realloc(
            null,
            @sizeOf(*pdapi.LCDBitmap) * max_bitmaps,
        ) orelse unreachable));
        var bitlib = BitmapLib{
            .bitmaps = bitmaps_ptr[0..max_bitmaps],
            .playdate = playdate,
        };
        if (debug) playdate.system.logToConsole("len of bitlibs %d", bitlib.bitmaps.len);
        bitlib.bitmaps.len = 0;
        return bitlib;
    }

    fn deinit(self: *BitmapLib) void {
        for (self.bitmaps) |bitmap| {
            self.playdate.graphics.freeBitmap(bitmap);
        }
        self.bitmaps.len = 0;
    }

    fn addMap(self: *BitmapLib, bitmap: *pdapi.LCDBitmap) error{LibraryFull}!void {
        if (self.bitmaps.len + 1 >= max_bitmaps) return error.LibraryFull;
        self.bitmaps.len += 1;
        self.bitmaps[self.bitmaps.len - 1] = bitmap;
    }
};

const BitmapLibParser = struct {
    in_spec: bool = false,
    resx: c_int = 0,
    resy: c_int = 0,
    has_mask: bool = false,
    bitlib: *BitmapLib,

    fn decodeError(decoder: ?*pdapi.JSONDecoder, jerror: ?[*:0]const u8, linenum: c_int) callconv(.C) void {
        const jstate: *const BitmapLibParser = @ptrCast(@alignCast((decoder orelse return).userdata));
        const bitlib = jstate.bitlib;
        const pd = bitlib.playdate;
        pd.system.logToConsole("decodeError: %s %d", jerror, linenum);
    }

    fn willDecodeSublist(decoder: ?*pdapi.JSONDecoder, name: ?[*:0]const u8, jtype: pdapi.JSONValueType) callconv(.C) void {
        const jstate: *BitmapLibParser = @ptrCast(@alignCast((decoder orelse return).userdata));
        const bitlib = jstate.bitlib;
        const pd = bitlib.playdate;

        if (jtype == .JSONArray and std.mem.eql(u8, "spec", std.mem.sliceTo(name.?, 0))) {
            jstate.in_spec = true;
        } else {
            jstate.in_spec = false;
        }
        if (debug) pd.system.logToConsole("[%s] willDecodeSublist: %s", decoder.?.path, name);
    }

    //fn shouldDecodeTableValueForKey(decoder: ?*pdapi.JSONDecoder, key: ?[*:0]const u8) callconv(.C) c_int {}

    fn didDecodeTableValue(decoder: ?*pdapi.JSONDecoder, key: ?[*:0]const u8, value: pdapi.JSONValue) callconv(.C) void {
        const jstate: *BitmapLibParser = @ptrCast(@alignCast((decoder orelse return).userdata));
        const bitlib = jstate.bitlib;
        const pd = bitlib.playdate;

        if (value.type != @intFromEnum(pdapi.JSONValueType.JSONString)) {
            return;
        }
        const key_name = std.mem.sliceTo(key orelse return, 0);

        var row_bytes: c_int = 0;
        var image_width: c_int = 0;
        var image_height: c_int = 0;
        var mask: [*c]u8 = null;
        var data: [*c]u8 = null;
        if (std.mem.eql(u8, "img", key_name)) {
            const bitmap = pd.graphics.newBitmap(
                jstate.resx,
                jstate.resy,
                if (jstate.has_mask) @intFromEnum(pdapi.LCDSolidColor.ColorClear) else @intFromEnum(pdapi.LCDSolidColor.ColorBlack),
            ) orelse return;
            pd.graphics.getBitmapData(
                bitmap,
                &image_width,
                &image_height,
                &row_bytes,
                &mask,
                &data,
            );
            std.debug.assert(jstate.resx == image_width and jstate.resy == image_height);
            const img_str = std.mem.sliceTo(value.data.stringval, 0);
            const decode_size = std.base64.url_safe.Decoder.calcSizeForSlice(img_str) catch {
                _ = pd.system.realloc(bitmap, 0);
                pd.system.logToConsole("Failed to calc size of %s", key);
                return;
            };
            if (decode_size == row_bytes * image_height) {
                std.base64.url_safe.Decoder.decode(data[0..@intCast(row_bytes * image_height)], img_str) catch {
                    _ = pd.system.realloc(bitmap, 0);
                    pd.system.logToConsole("Failed to decode %s", key);
                    return;
                };
                bitlib.addMap(bitmap) catch {
                    _ = pd.system.realloc(bitmap, 0);
                    pd.system.logToConsole("Bitmap Library Full");
                };
            }
        } else if (std.mem.eql(u8, "img_mask", key_name)) {
            pd.graphics.getBitmapData(
                bitlib.bitmaps[bitlib.bitmaps.len - 1],
                &image_width,
                &image_height,
                &row_bytes,
                &mask,
                &data,
            );
            // Instead of checking the value.type for a JSONNull, we rely on the fact that
            // the spec specified a mask or not for when the LCDBitmap was created.
            if (mask == null) {
                pd.system.logToConsole("No mask set");
                return;
            }

            const img_str = std.mem.sliceTo(value.data.stringval, 0);
            const decode_size = std.base64.url_safe.Decoder.calcSizeForSlice(img_str) catch {
                pd.system.logToConsole("Failed to calc size of %s", key);
                return;
            };
            if (decode_size == row_bytes * image_height) {
                std.base64.url_safe.Decoder.decode(mask[0..@intCast(row_bytes * image_height)], img_str) catch {
                    pd.system.logToConsole("Failed to decode %s", key);
                    return;
                };
            }
        }
        if (debug) pd.system.logToConsole("[%s] didDecodeTableValue: %s", decoder.?.path, key);
    }

    //fn shouldDecodeArrayValueAtIndex(decoder: ?*pdapi.JSONDecoder, pos: c_int) callconv(.C) c_int {}

    fn didDecodeArrayValue(decoder: ?*pdapi.JSONDecoder, pos: c_int, value: pdapi.JSONValue) callconv(.C) void {
        const jstate: *BitmapLibParser = @ptrCast(@alignCast((decoder orelse return).userdata));
        const bitlib = jstate.bitlib;
        const pd = bitlib.playdate;
        if (jstate.in_spec and (value.type >= @intFromEnum(pdapi.JSONValueType.JSONTrue) or value.type <= @intFromEnum(pdapi.JSONValueType.JSONInteger))) {
            switch (pos) {
                1 => jstate.resx = value.data.intval,
                2 => jstate.resy = value.data.intval,
                3 => jstate.has_mask = (value.type == @intFromEnum(pdapi.JSONValueType.JSONTrue)),
                else => return,
            }
        }
        if (debug) pd.system.logToConsole("didDecodeArrayValue: %d", pos);
    }

    fn didDecodeSublist(decoder: ?*pdapi.JSONDecoder, name: ?[*:0]const u8, jtype: pdapi.JSONValueType) callconv(.C) ?*anyopaque {
        _ = jtype;
        const jstate: *BitmapLibParser = @ptrCast(@alignCast((decoder orelse return null).userdata));
        const bitlib = jstate.bitlib;
        const pd = bitlib.playdate;
        jstate.in_spec = false;
        if (debug) pd.system.logToConsole("didDecodeSublist: %s", name);
        return null;
    }

    fn buildLibrary(self: *BitmapLibParser) void {
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
        _ = self.bitlib.playdate.json.decodeString(&json_decoder, library, null);
        if (debug) self.bitlib.playdate.system.logToConsole("[%d] [%d]", self.resx, self.resy, self.has_mask);
    }
};

pub export fn eventHandler(playdate: *pdapi.PlaydateAPI, event: pdapi.PDSystemEvent, arg: u32) callconv(.C) c_int {
    _ = arg;
    switch (event) {
        .EventInit => {
            //NOTE: Initalizing the panic handler should be the first thing that is done.
            //      If a panic happens before calling this, the simulator or hardware will
            //      just crash with no message.
            panic_handler.init(playdate);

            if (debug) playdate.system.logToConsole("Json Size: %d\n", library.len);

            var bitmap_lib = BitmapLib.init(playdate);
            var json_builder = BitmapLibParser{ .bitlib = &bitmap_lib };
            json_builder.buildLibrary();

            var level = Level.init(playdate);
            const sprite = playdate.sprite.newSprite() orelse unreachable;
            playdate.sprite.setImage(sprite, bitmap_lib.bitmaps[0], .BitmapUnflipped);
            // This is required since the flipped arg of setImage doesn't seem to work.
            playdate.sprite.setImageFlip(sprite, .BitmapFlippedY);
            playdate.sprite.setCenter(sprite, 0.0, 0.0);
            playdate.sprite.moveTo(sprite, 128.0, 64.0);
            playdate.sprite.setSize(sprite, 128.0, 128.0);
            playdate.sprite.addSprite(sprite);
            level.addSprite(sprite) catch {
                playdate.system.logToConsole("Level Full");
            };

            const global_state: *GlobalState =
                @ptrCast(@alignCast(
                    playdate.system.realloc(null, @sizeOf(GlobalState)),
                ));
            global_state.* = .{
                .playdate = playdate,
                .pos = .{ .x = 0, .y = 0 },
                .frame = 0,
                .flipped = false,
                .bitlib = bitmap_lib,
                .level = level,
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

    var delta = Position{ .x = 0, .y = 0 };
    if (pdapi.BUTTON_LEFT & current_buttons != 0) delta.x = -2;
    if (pdapi.BUTTON_RIGHT & current_buttons != 0) delta.x = 2;
    if (pdapi.BUTTON_UP & current_buttons != 0) delta.y = -2;
    if (pdapi.BUTTON_DOWN & current_buttons != 0) delta.y = 2;

    global_state.pos.x += delta.x;
    global_state.pos.y += delta.y;

    if (delta.x < 0) global_state.flipped = true;
    if (delta.x > 0) global_state.flipped = false;

    playdate.sprite.drawSprites();

    playdate.graphics.drawBitmap(
        global_state.bitlib.bitmaps[global_state.frame + 1],
        @as(c_int, global_state.pos.x),
        @as(c_int, global_state.pos.y),
        if (global_state.flipped) .BitmapFlippedXY else .BitmapFlippedY,
    );
    if (delta.x != 0 or delta.y != 0) global_state.frame = (global_state.frame + 1) % 18;

    return 1;
}

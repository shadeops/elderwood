const std = @import("std");
const builtin = @import("builtin");
const pdapi = @import("playdate_api_definitions.zig");
const panic_handler = @import("panic_handler.zig");

const level = @embedFile("library.json");

pub const panic = panic_handler.panic;

const GlobalState = struct {
    playdate: *pdapi.PlaydateAPI,
    tree: *pdapi.LCDBitmap,
    font: *pdapi.LCDFont,
    pos: Position,
    tile_map: *TiledBG,
    bitlib: BitmapLibrary,
};

const Position = struct {
    x: i8,
    y: i8,
};

const debug = builtin.mode == .Debug;

const BitmapLibrary = struct {
    const max_bitmaps = 128;

    bitmaps: []*pdapi.LCDBitmap,
    playdate: *const pdapi.PlaydateAPI,
    tmp_res: [2]c_int = [2]c_int{ 0, 0 },
    tmp_is_res: bool = false,

    fn init(playdate: *const pdapi.PlaydateAPI) BitmapLibrary {
        const bitmaps_ptr: [*]*pdapi.LCDBitmap = @ptrCast(@alignCast(playdate.system.realloc(null, @sizeOf(*pdapi.LCDBitmap) * max_bitmaps,) orelse unreachable));
        var bitlib = BitmapLibrary{
            .bitmaps = bitmaps_ptr[0..max_bitmaps],
            .playdate = playdate,
        };
        if (debug) bitlib.playdate.system.logToConsole("len of bitlibs %d", bitlib.bitmaps.len);
        bitlib.bitmaps.len = 0;
        return bitlib;
    }

    fn addMap(self: *BitmapLibrary, bitmap: *pdapi.LCDBitmap) error{LibraryFull}!void {
        if (self.bitmaps.len + 1 >= max_bitmaps) return error.LibraryFull;
        self.bitmaps.len += 1;
        self.bitmaps[self.bitmaps.len - 1] = bitmap;
    }

    fn decodeError(decoder: ?*pdapi.JSONDecoder, jerror: ?[*:0]const u8, linenum: c_int) callconv(.C) void {
        const bitlib: *const BitmapLibrary = @ptrCast(@alignCast((decoder orelse return).userdata));
        bitlib.playdate.system.logToConsole("decodeError: %s %d", jerror, linenum);
    }
    fn willDecodeSublist(decoder: ?*pdapi.JSONDecoder, name: ?[*:0]const u8, jtype: pdapi.JSONValueType) callconv(.C) void {
        const bitlib: *BitmapLibrary = @ptrCast(@alignCast((decoder orelse return).userdata));
        if (jtype == .JSONArray and std.mem.eql(u8, "res", std.mem.sliceTo(name.?, 0))) {
            bitlib.tmp_is_res = true;
        } else {
            bitlib.tmp_is_res = false;
        }
        if (debug) bitlib.playdate.system.logToConsole("[%s] willDecodeSublist: %s", decoder.?.path, name);
    }
    //fn shouldDecodeTableValueForKey(decoder: ?*pdapi.JSONDecoder, key: ?[*:0]const u8) callconv(.C) c_int {
    //    const bitlib: *const BitmapLibrary = @ptrCast(@alignCast((decoder orelse return 0).userdata));
    //    bitlib.playdate.system.logToConsole("shouldDecodeTableValueForKey: %s", key);
    //    return 1;
    //}
    fn didDecodeTableValue(decoder: ?*pdapi.JSONDecoder, key: ?[*:0]const u8, value: pdapi.JSONValue) callconv(.C) void {
        const bitlib: *BitmapLibrary = @ptrCast(@alignCast((decoder orelse return).userdata));

        if (value.type != @intFromEnum(pdapi.JSONValueType.JSONString)) {
            return;
        }
        const key_name = std.mem.sliceTo(key orelse return, 0);
        const img_str = std.mem.sliceTo(value.data.stringval, 0);

        var row_bytes: c_int = 0;
        var image_width: c_int = 0;
        var image_height: c_int = 0;
        var mask: [*c]u8 = null;
        var data: [*c]u8 = null;
        if (std.mem.eql(u8, "img", key_name)) {
            const bitmap = bitlib.playdate.graphics.newBitmap(
                bitlib.tmp_res[0],
                bitlib.tmp_res[1],
                @intFromEnum(pdapi.LCDSolidColor.ColorClear),
            ) orelse return;
            bitlib.playdate.graphics.getBitmapData(
                bitmap,
                &image_width,
                &image_height,
                &row_bytes,
                &mask,
                &data,
            );
            std.debug.assert(bitlib.tmp_res[0] * bitlib.tmp_res[1] == image_width * image_height);
            const decode_size = std.base64.url_safe.Decoder.calcSizeForSlice(img_str) catch {
                _ = bitlib.playdate.system.realloc(bitmap, 0);
                bitlib.playdate.system.logToConsole("Failed to calc size of %s", key);
                return;
            };
            if (decode_size == row_bytes * image_height) {
                std.base64.url_safe.Decoder.decode(data[0..@intCast(row_bytes * image_height)], img_str) catch {
                    _ = bitlib.playdate.system.realloc(bitmap, 0);
                    bitlib.playdate.system.logToConsole("Failed to decode %s", key);
                    return;
                };
                bitlib.addMap(bitmap) catch {
                    _ = bitlib.playdate.system.realloc(bitmap, 0);
                    bitlib.playdate.system.logToConsole("Bitmap Library Full");
                };
            }
        } else if (std.mem.eql(u8, "img_mask", key_name)) {
            bitlib.playdate.graphics.getBitmapData(
                bitlib.bitmaps[bitlib.bitmaps.len - 1],
                &image_width,
                &image_height,
                &row_bytes,
                &mask,
                &data,
            );
            if (mask == null) {
                bitlib.playdate.system.logToConsole("No mask set");
                return;
            }
            const decode_size = std.base64.url_safe.Decoder.calcSizeForSlice(img_str) catch {
                bitlib.playdate.system.logToConsole("Failed to calc size of %s", key);
                return;
            };
            if (decode_size == row_bytes * image_height) {
                std.base64.url_safe.Decoder.decode(mask[0..@intCast(row_bytes * image_height)], img_str) catch {
                    bitlib.playdate.system.logToConsole("Failed to decode %s", key);
                    return;
                };
            }
        }
        if (debug) bitlib.playdate.system.logToConsole("[%s] didDecodeTableValue: %s", decoder.?.path, key);
    }
    //fn shouldDecodeArrayValueAtIndex(decoder: ?*pdapi.JSONDecoder, pos: c_int) callconv(.C) c_int {
    //    const bitlib: *const BitmapLibrary = @ptrCast(@alignCast((decoder orelse return 0).userdata));
    //    bitlib.playdate.system.logToConsole("shouldDecodeArrayValueAtIndex: %d", pos);
    //    return 1;
    //}
    fn didDecodeArrayValue(decoder: ?*pdapi.JSONDecoder, pos: c_int, value: pdapi.JSONValue) callconv(.C) void {
        const bitlib: *BitmapLibrary = @ptrCast(@alignCast((decoder orelse return).userdata));
        if (bitlib.tmp_is_res and pos > 0 and pos < 3 and value.type == @intFromEnum(pdapi.JSONValueType.JSONInteger)) {
            bitlib.tmp_res[@intCast(pos - 1)] = value.data.intval;
        }
        if (debug) bitlib.playdate.system.logToConsole("didDecodeArrayValue: %d", pos);
    }
    fn didDecodeSublist(decoder: ?*pdapi.JSONDecoder, name: ?[*:0]const u8, jtype: pdapi.JSONValueType) callconv(.C) ?*anyopaque {
        _ = jtype;
        const bitlib: *BitmapLibrary = @ptrCast(@alignCast((decoder orelse return null).userdata));
        bitlib.tmp_is_res = false;
        if (debug) bitlib.playdate.system.logToConsole("didDecodeSublist: %s", name);
        return null;
    }

    fn buildLibrary(self: *BitmapLibrary) void {
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
        _ = self.playdate.json.decodeString(&json_decoder, level, null);
        if (debug) self.playdate.system.logToConsole("[%d] [%d]", self.tmp_res[0], self.tmp_res[1]);
    }
};

const TiledBG = struct {
    const tile_size = 32;
    const screen_tiles_x = @divFloor(pdapi.LCD_COLUMNS, tile_size) + 2;
    const screen_tiles_y = @divFloor(pdapi.LCD_ROWS, tile_size) + 2;
    const screen_tiles = screen_tiles_x * screen_tiles_y;
    const grid_tiles_x = 10;
    const grid_tiles_y = 10;

    offsetx: i8,
    offsety: i8,
    tile_map_table: *pdapi.LCDBitmapTable,
    tile_map: *pdapi.LCDTileMap,

    fn updatePos(self: *TiledBG, pos: *Position, delta: Position) void {
        pos.x += delta.x;
        pos.y += delta.y;

        if (pos.x > 0) {
            self.offsetx -= 1;
            pos.x = pos.x - tile_size;
        } else if (pos.x <= -tile_size) {
            self.offsetx += 1;
            pos.x = @rem(pos.x, tile_size);
        }
        if (pos.y > 0) {
            self.offsety -= 1;
            pos.y = pos.y - tile_size;
        } else if (pos.y <= -tile_size) {
            self.offsety += 1;
            pos.y = @mod(pos.y, tile_size);
        }

        self.offsetx = @rem(self.offsetx, grid_tiles_x);
        self.offsety = @rem(self.offsety, grid_tiles_y);
    }

    fn updateTiles(self: TiledBG, playdate: *const pdapi.PlaydateAPI) void {
        var tile_idxs = [_]u16{0} ** (screen_tiles);
        for (&tile_idxs, 0..) |*t, i| {
            // screen tiles
            // x: 0 -> 14
            // y: 0 -> 9
            const screen_row: i32 = @intCast(i / screen_tiles_x);
            const screen_col: i32 = @intCast(i % screen_tiles_x);
            const x_tile: i32 = self.offsetx + @mod(screen_col, grid_tiles_x);
            const y_tile: i32 = self.offsety + @mod(screen_row, grid_tiles_y);
            t.* = @intCast(@mod(y_tile, grid_tiles_y) * grid_tiles_x + @mod(x_tile, grid_tiles_x));
        }
        playdate.graphics.tilemap.setTiles(self.tile_map, &tile_idxs, tile_idxs.len, screen_tiles_x);
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

            const tree_map = playdate.graphics.loadBitmap("assets/images/test_tree", null).?;
            var image_width: c_int = 0;
            var image_height: c_int = 0;
            var mask: [*c]u8 = undefined;
            playdate.graphics.getBitmapData(
                tree_map,
                &image_width,
                &image_height,
                null,
                &mask,
                null,
            );
            if (debug) playdate.system.logToConsole("Json Size: %d\n", level.len);
            
            var bitmap_lib = BitmapLibrary.init(playdate);
            bitmap_lib.buildLibrary();

            const tiled_bg: *TiledBG = @ptrCast(@alignCast(
                playdate.system.realloc(null, @sizeOf(TiledBG)),
            ));
            tiled_bg.offsetx = 0;
            tiled_bg.offsety = 0;
            tiled_bg.tile_map_table = playdate.graphics.loadBitmapTable("assets/images/grid", null).?;
            tiled_bg.tile_map = playdate.graphics.tilemap.newTilemap().?;
            playdate.graphics.tilemap.setImageTable(tiled_bg.tile_map, tiled_bg.tile_map_table);

            const font = playdate.graphics.loadFont("/System/Fonts/Roobert-11-Medium.pft", null).?;
            playdate.graphics.setFont(font);

            const global_state: *GlobalState =
                @ptrCast(@alignCast(
                    playdate.system.realloc(null, @sizeOf(GlobalState)),
                ));
            global_state.* = .{
                .tree = tree_map,
                .tile_map = tiled_bg,
                .playdate = playdate,
                .pos = .{ .x = 0, .y = 0 },
                .font = font,
                .bitlib = bitmap_lib,
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
    const tile_map = global_state.tile_map;

    const draw_mode: pdapi.LCDBitmapDrawMode = .DrawModeCopy;
    const clear_color: pdapi.LCDSolidColor = .ColorWhite;

    var current_buttons: pdapi.PDButtons = undefined;
    var pushed_buttons: pdapi.PDButtons = undefined;
    var released_buttons: pdapi.PDButtons = undefined;
    playdate.system.getButtonState(&current_buttons, &pushed_buttons, &released_buttons);

    playdate.graphics.setDrawMode(draw_mode);
    playdate.graphics.clear(@intCast(@intFromEnum(clear_color)));

    var delta = Position{ .x = 0, .y = 0 };
    if (pdapi.BUTTON_LEFT & current_buttons != 0) delta.x = 2;
    if (pdapi.BUTTON_RIGHT & current_buttons != 0) delta.x = -2;
    if (pdapi.BUTTON_UP & current_buttons != 0) delta.y = 2;
    if (pdapi.BUTTON_DOWN & current_buttons != 0) delta.y = -2;

    tile_map.updatePos(&global_state.pos, delta);

    tile_map.updateTiles(playdate);
    playdate.graphics.tilemap.drawAtPoint(
        tile_map.tile_map,
        @floatFromInt(global_state.pos.x),
        @floatFromInt(global_state.pos.y),
    );

    playdate.graphics.drawBitmap(
        global_state.bitlib.bitmaps[0],
        //global_state.tree,
        @as(c_int, global_state.pos.x) + 128,
        @as(c_int, global_state.pos.y) + 128,
        .BitmapFlippedY,
    );

    if (false) {
        var buffer: [*c]u8 = null;
        const str_len = playdate.system.formatString(
            &buffer,
            "offsetx: %d\noffsety: %d\nposx: %d\nposy: %d",
            tile_map.offsetx,
            tile_map.offsety,
            global_state.pos.x,
            global_state.pos.y,
        );
        if (buffer != null) {
            defer {
                _ = playdate.system.realloc(@ptrCast(buffer), 0);
                buffer = null;
            }
            playdate.graphics.fillRect(90, 50, 150, 100, @intFromEnum(clear_color));
            const pixel_width = playdate.graphics.drawText(@ptrCast(buffer.?), @intCast(str_len), .UTF8Encoding, 100, 50);
            _ = pixel_width;
        }
    }

    //returning 1 signals to the OS to draw the frame.
    //we always want this frame drawn
    return 1;
}

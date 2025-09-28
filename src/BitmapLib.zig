const enable_debug = false;
const debug = if (builtin.mode == .Debug and enable_debug) true else false;

const playdate = @import("PDapi.zig");

const BitmapLib = @This();

bitmaps: []*pdapi.LCDBitmap = &.{},

pub fn isEmpty(self: BitmapLib) bool {
    return self.bitmaps.len == 0;
}

pub fn clear(self: *BitmapLib) void {
    for (self.bitmaps) |bitmap| {
        playdate.graphics.freeBitmap(bitmap);
    }
    self.bitmaps = &.{};
}

const BitmapLibParser = struct {
    in_spec: bool = false,
    resx: c_int = 0,
    resy: c_int = 0,
    has_mask: bool = false,
    game_state: *GlobalState,

    added_bitmaps: usize = 0,

    fn decodeError(decoder: ?*pdapi.JSONDecoder, jerror: ?[*:0]const u8, linenum: c_int) callconv(.C) void {
        _ = decoder;
        playdate.system.logToConsole("decodeError: %s %d", jerror, linenum);
    }

    fn willDecodeSublist(decoder: ?*pdapi.JSONDecoder, name: ?[*:0]const u8, jtype: pdapi.JSONValueType) callconv(.C) void {
        const jstate: *BitmapLibParser = @ptrCast(@alignCast((decoder orelse return).userdata));

        if (jtype == .JSONArray and std.mem.eql(u8, "spec", std.mem.sliceTo(name.?, 0))) {
            jstate.in_spec = true;
        } else {
            jstate.in_spec = false;
        }
        if (debug) playdate.system.logToConsole("[%s] willDecodeSublist: %s", decoder.?.path, name);
    }

    fn didDecodeTableValue(decoder: ?*pdapi.JSONDecoder, key: ?[*:0]const u8, value: pdapi.JSONValue) callconv(.C) void {
        const jstate: *BitmapLibParser = @ptrCast(@alignCast((decoder orelse return).userdata));
        const bitlib = &jstate.game_state.bitmap_lib;

        if (debug) playdate.system.logToConsole("[%s] didDecodeTableValue: %s %d", decoder.?.path, key, value.type);
        if (value.type != @intFromEnum(pdapi.JSONValueType.JSONString) and value.type != @intFromEnum(pdapi.JSONValueType.JSONInteger)) {
            return;
        }
        const key_name = std.mem.sliceTo(key orelse return, 0);

        var row_bytes: c_int = 0;
        var image_width: c_int = 0;
        var image_height: c_int = 0;
        var mask: [*c]u8 = null;
        var data: [*c]u8 = null;
        if (std.mem.eql(u8, ".total_sprites.", key_name) and value.type == @intFromEnum(pdapi.JSONValueType.JSONInteger)) {
            // This must be first in bitmap_library array for the allocation to take place.
            if (value.data.intval < 0) {
                playdate.system.logToConsole("ERROR: Invalid number of sprites");
                return;
            }
            const bitmaps_ptr: [*]*pdapi.LCDBitmap = @ptrCast(@alignCast(playdate.system.realloc(
                null,
                @intCast(@sizeOf(*pdapi.LCDBitmap) * (value.data.intval)),
            ) orelse unreachable));
            bitlib.bitmaps = bitmaps_ptr[0..@intCast(value.data.intval)];
            jstate.added_bitmaps = 0;
            if (debug) playdate.system.logToConsole("len of bitlibs %d", bitlib.bitmaps.len);
        } else if (std.mem.eql(u8, "img", key_name)) {
            const bitmap = playdate.graphics.newBitmap(
                jstate.resx,
                jstate.resy,
                if (jstate.has_mask) @intFromEnum(pdapi.LCDSolidColor.ColorClear) else @intFromEnum(pdapi.LCDSolidColor.ColorBlack),
            ) orelse return;
            playdate.graphics.getBitmapData(
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
                _ = playdate.graphics.freeBitmap(bitmap);
                playdate.system.logToConsole("Failed to calc size of %s", key);
                return;
            };
            if (decode_size == row_bytes * image_height) {
                std.base64.url_safe.Decoder.decode(data[0..@intCast(row_bytes * image_height)], img_str) catch {
                    _ = playdate.graphics.freeBitmap(bitmap);
                    playdate.system.logToConsole("Failed to decode %s", key);
                    return;
                };
                jstate.addMap(bitmap) catch {
                    _ = playdate.graphics.freeBitmap(bitmap);
                    playdate.system.logToConsole("Bitmap Library Full");
                };
            }
        } else if (std.mem.eql(u8, "img_mask", key_name)) {
            playdate.graphics.getBitmapData(
                bitlib.bitmaps[jstate.added_bitmaps - 1],
                &image_width,
                &image_height,
                &row_bytes,
                &mask,
                &data,
            );
            // Instead of checking the value.type for a JSONNull, we rely on the fact that
            // the spec specified a mask or not for when the LCDBitmap was created.
            if (mask == null) {
                playdate.system.logToConsole("No mask set");
                return;
            }

            const img_str = std.mem.sliceTo(value.data.stringval, 0);
            const decode_size = std.base64.url_safe.Decoder.calcSizeForSlice(img_str) catch {
                playdate.system.logToConsole("Failed to calc size of %s", key);
                return;
            };
            if (decode_size == row_bytes * image_height) {
                std.base64.url_safe.Decoder.decode(mask[0..@intCast(row_bytes * image_height)], img_str) catch {
                    playdate.system.logToConsole("Failed to decode %s", key);
                    return;
                };
            }
        }
    }

    fn didDecodeArrayValue(decoder: ?*pdapi.JSONDecoder, pos: c_int, value: pdapi.JSONValue) callconv(.C) void {
        const jstate: *BitmapLibParser = @ptrCast(@alignCast((decoder orelse return).userdata));
        if (jstate.in_spec and (value.type >= @intFromEnum(pdapi.JSONValueType.JSONTrue) or value.type <= @intFromEnum(pdapi.JSONValueType.JSONInteger))) {
            switch (pos) {
                1 => jstate.resx = value.data.intval,
                2 => jstate.resy = value.data.intval,
                3 => jstate.has_mask = (value.type == @intFromEnum(pdapi.JSONValueType.JSONTrue)),
                else => return,
            }
        }
        if (debug) playdate.system.logToConsole("didDecodeArrayValue: %d", pos);
    }

    fn didDecodeSublist(decoder: ?*pdapi.JSONDecoder, name: ?[*:0]const u8, jtype: pdapi.JSONValueType) callconv(.C) ?*anyopaque {
        _ = jtype;
        const jstate: *BitmapLibParser = @ptrCast(@alignCast((decoder orelse return null).userdata));
        jstate.in_spec = false;
        if (debug) playdate.system.logToConsole("didDecodeSublist: %s", name);
        return null;
    }

    fn addMap(self: *BitmapLibParser, bitmap: *pdapi.LCDBitmap) error{LibraryFull}!void {
        const bitlib = &self.game_state.bitmap_lib;
        if (debug) bitlib.playdate.system.logToConsole("Adding bitmap: %d", bitlib.bitmaps.len);
        if (self.added_bitmaps + 1 > bitlib.bitmaps.len) return error.LibraryFull;
        self.added_bitmaps += 1;
        bitlib.bitmaps[self.added_bitmaps - 1] = bitmap;
    }

    fn initDecoder(self: *BitmapLibParser) pdapi.JSONDecoder {
        return pdapi.JSONDecoder{
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

pub fn buildLibrary(game_state: *GlobalState) void {
    game_state.state = blk: switch (game_state.bitmap_lib_src) {
        .string => |s| {
            var bitmap_parser = BitmapLibParser{ .game_state = game_state };
            var json_decoder = bitmap_parser.initDecoder();
            _ = playdate.json.decodeString(&json_decoder, s, null);
            break :blk .init;
        },
        .file => |f| {
            var library_reader = JsonReader.init("assets/", f) catch {
                playdate.system.logToConsole("ERROR: failed to build bitmap library");
                return;
            };
            defer library_reader.deinit();
            var bitmap_parser = BitmapLibParser{ .game_state = game_state };
            var json_decoder = bitmap_parser.initDecoder();
            _ = playdate.json.decode(&json_decoder, library_reader.json_reader, null);
            break :blk .init;
        },
        .http => |h| {
            const hconn = playdate.network.http.newConnection(h.host, h.port, false) orelse {
                playdate.system.logToConsole("Failed to create connection");
                return;
            };
            playdate.network.http.setReadBufferSize(hconn, 1024 * 128);
            playdate.network.http.setUserdata(hconn, @ptrCast(game_state));
            playdate.network.http.setRequestCompleteCallback(hconn, HTTPRequestCompleteCallback);
            //http.setResponseCallback(hconn, HTTPRequestCompleteCallback);
            const err = playdate.network.http.get(hconn, "/bitmap_library", null, 0);
            playdate.system.logToConsole("http get(), err=%i", @intFromEnum(err));
            break :blk .http_wait_for_response;
        },
    };
}

fn HTTPRequestCompleteCallback(conn: ?*pdapi.HTTPConnection) callconv(.C) void {

    // TODO: this orelse should set a gamestate otherwise inf loop

    if (debug) playdate.system.logToConsole("BitmapLib HTTP Request Callback");

    // Must free response
    const response = http.readResponse(conn orelse return);
    defer _ = playdate.system.realloc(response.ptr, 0);

    const game_state: *GlobalState = @ptrCast(@alignCast(playdate.network.http.getUserdata(conn)));

    playdate.system.logToConsole("About to Parse String");
    var bitmap_parser = BitmapLibParser{ .game_state = game_state };
    var json_decoder = bitmap_parser.initDecoder();
    _ = playdate.json.decodeString(&json_decoder, response.ptr, null);
    game_state.state = .init;
    playdate.system.logToConsole("Parsed String");
}

const std = @import("std");
const builtin = @import("builtin");
const pdapi = @import("playdate_api_definitions.zig");

const base_types = @import("base_types.zig");
const http = @import("http.zig");

const JsonReader = base_types.JsonReader;
const GlobalState = @import("GlobalState.zig");

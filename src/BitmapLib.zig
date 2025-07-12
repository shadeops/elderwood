const library = @embedFile("library.json");

const enable_debug = false;
const debug = if (builtin.mode == .Debug and enable_debug) true else false;

const BitmapLib = @This();

bitmaps: []*pdapi.LCDBitmap = &.{},
playdate: *const pdapi.PlaydateAPI,

pub fn init(playdate: *const pdapi.PlaydateAPI) *BitmapLib {
    const bitlib_ptr: *BitmapLib = @ptrCast(@alignCast(playdate.system.realloc(null, @sizeOf(BitmapLib))));
    bitlib_ptr.* = BitmapLib{
        .playdate = playdate,
    };
    return bitlib_ptr;
}

pub fn deinit(self: *BitmapLib) void {
    for (self.bitmaps) |bitmap| {
        self.playdate.graphics.freeBitmap(bitmap);
    }
    self.bitmaps = &.{};
    _ = self.playdate.system.realloc(self.bitmaps.ptr, 0);
}

pub const BitmapLibParser = struct {
    in_spec: bool = false,
    resx: c_int = 0,
    resy: c_int = 0,
    has_mask: bool = false,
    bitlib: *BitmapLib,
    added_bitmaps: usize = 0,

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

        if (debug) pd.system.logToConsole("[%s] didDecodeTableValue: %s %d", decoder.?.path, key, value.type);
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
                pd.system.logToConsole("ERROR: Invalid number of sprites");
                return;
            }
            const bitmaps_ptr: [*]*pdapi.LCDBitmap = @ptrCast(@alignCast(pd.system.realloc(
                null,
                @intCast(@sizeOf(*pdapi.LCDBitmap) * (value.data.intval)),
            ) orelse unreachable));
            bitlib.bitmaps = bitmaps_ptr[0..@intCast(value.data.intval)];
            jstate.added_bitmaps = 0;
            if (debug) pd.system.logToConsole("len of bitlibs %d", bitlib.bitmaps.len);
        } else if (std.mem.eql(u8, "img", key_name)) {
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
                _ = pd.graphics.freeBitmap(bitmap);
                pd.system.logToConsole("Failed to calc size of %s", key);
                return;
            };
            if (decode_size == row_bytes * image_height) {
                std.base64.url_safe.Decoder.decode(data[0..@intCast(row_bytes * image_height)], img_str) catch {
                    _ = pd.graphics.freeBitmap(bitmap);
                    pd.system.logToConsole("Failed to decode %s", key);
                    return;
                };
                jstate.addMap(bitmap) catch {
                    _ = pd.graphics.freeBitmap(bitmap);
                    pd.system.logToConsole("Bitmap Library Full");
                };
            }
        } else if (std.mem.eql(u8, "img_mask", key_name)) {
            pd.graphics.getBitmapData(
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

    pub fn addMap(self: *BitmapLibParser, bitmap: *pdapi.LCDBitmap) error{LibraryFull}!void {
        if (debug) self.bitlib.playdate.system.logToConsole("Adding bitmap: %d", self.bitlib.bitmaps.len);
        if (self.added_bitmaps + 1 > self.bitlib.bitmaps.len) return error.LibraryFull;
        self.added_bitmaps += 1;
        self.bitlib.bitmaps[self.added_bitmaps - 1] = bitmap;
    }

    pub fn buildLibrary(self: *BitmapLibParser, library_src: JsonSource) void {
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
        
        switch (library_src) {
            .string => |s| _ = self.bitlib.playdate.json.decodeString(&json_decoder, s, null),
            .file => |f| {
                var library_reader = JsonReader.init(self.bitlib.playdate, "assets/", f) catch {
                    self.bitlib.playdate.system.logToConsole("ERROR: failed to build bitmap library");
                    return;
                };
                defer library_reader.deinit();
                 _ = self.bitlib.playdate.json.decode(&json_decoder, library_reader.json_reader, null);
            },
        }
    }
};


const std = @import("std");
const builtin = @import("builtin");
const pdapi = @import("playdate_api_definitions.zig");

const base_types = @import("base_types.zig");

const JsonSource = base_types.JsonSource;
const JsonReader = base_types.JsonReader;


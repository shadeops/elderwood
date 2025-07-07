const std = @import("std");
const builtin = @import("builtin");
const pdapi = @import("playdate_api_definitions.zig");

const library = @embedFile("library.json");

const enable_debug = false;
const debug = if (builtin.mode == .Debug and enable_debug) true else false;

const BitmapLib = @This();
const max_bitmaps = 128;

bitmaps: []*pdapi.LCDBitmap,
playdate: *const pdapi.PlaydateAPI,

pub fn init(playdate: *const pdapi.PlaydateAPI) BitmapLib {
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

pub fn deinit(self: *BitmapLib) void {
    for (self.bitmaps) |bitmap| {
        self.playdate.graphics.freeBitmap(bitmap);
    }
    self.bitmaps.len = 0;
    _ = self.playdate.system.realloc(self.bitmaps.ptr, 0);
}

pub fn addMap(self: *BitmapLib, bitmap: *pdapi.LCDBitmap) error{LibraryFull}!void {
    if (self.bitmaps.len + 1 >= max_bitmaps) return error.LibraryFull;
    self.bitmaps.len += 1;
    self.bitmaps[self.bitmaps.len - 1] = bitmap;
}

pub const BitmapLibParser = struct {
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

    pub fn buildLibrary(self: *BitmapLibParser) void {
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
        if (debug) self.bitlib.playdate.system.logToConsole("Json Size: %d\n", library.len);

        _ = self.bitlib.playdate.json.decodeString(&json_decoder, library, null);
        if (debug) self.bitlib.playdate.system.logToConsole("[%d] [%d]", self.resx, self.resy, self.has_mask);
    }
};

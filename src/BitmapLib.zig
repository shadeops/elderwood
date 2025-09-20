const enable_debug = true;
const debug = if (builtin.mode == .Debug and enable_debug) true else false;

var global_playdate_ptr: ?*const pdapi.PlaydateAPI = null;

const BitmapLib = @This();

bitmaps: []*pdapi.LCDBitmap = &.{},
playdate: *const pdapi.PlaydateAPI,

pub fn init(playdate: *const pdapi.PlaydateAPI) *BitmapLib {
    if (global_playdate_ptr == null) {
        global_playdate_ptr = playdate;
    }

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
    _ = self.playdate.system.realloc(@ptrCast(self.bitmaps.ptr), 0);
}

pub const BitmapLibParser = struct {
    in_spec: bool = false,
    resx: c_int = 0,
    resy: c_int = 0,
    has_mask: bool = false,
    bitlib: *BitmapLib,
    game_state: *GlobalState,
    
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
            .http => |h| {

                const playdate = self.bitlib.playdate;
                const http = playdate.network.playdate_http;

                const hconn = http.newConnection(h.host, h.port, false) orelse {
                    playdate.system.logToConsole("Failed to create connection");
                    return;
                };
                http.setReadBufferSize(hconn, 1024*128);
                http.setUserdata(hconn, @ptrCast(self));
                http.setRequestCompleteCallback(hconn, HTTPRequestCompleteCallback);
                //http.setResponseCallback(hconn, HTTPRequestCompleteCallback);
                const err = http.get(hconn, "/bitmap_library", null, 0);
                playdate.system.logToConsole("http get(), err=%i", @intFromEnum(err));
                self.game_state.state = .wait_for_http_response;
            },
        }
    }
};

fn HTTPRequestCompleteCallback(conn: ?*pdapi.HTTPConnection) callconv(.C) void {
    const playdate = global_playdate_ptr orelse unreachable;
    playdate.system.logToConsole("Callback"); 
    const http = playdate.network.playdate_http;
                
    var read: i32 = 0;
    var total: i32 = 0;
    http.getProgress(conn, &read, &total);

    const bitmap_parser: *BitmapLibParser = @alignCast(@ptrCast(http.getUserdata(conn) orelse return));

    //const json_size: usize = @intCast(http.getBytesAvailable(conn));
    const json_size: usize = @intCast(total);
    playdate.system.logToConsole("Available Bytes: %i", json_size); 
     
    const getdata_ptr: [*:0]u8 = @ptrCast(@alignCast(playdate.system.realloc(null, @sizeOf(u8)*json_size+1)));
    getdata_ptr[json_size] = 0;
    getdata_ptr[json_size-1] = 0;

    defer {
        _ = playdate.system.realloc(getdata_ptr, 0);
    }

    const err = http.getError(conn);
    if (err != pdapi.PDNetErr.NET_OK ) {
        playdate.system.logToConsole("http request complete, err=%i", @intFromEnum(err));
    } else {
        playdate.system.logToConsole("http request complete, %i bytes available", json_size);
    }

    var offset: usize = 0;
    offset = @intCast(http.read(conn, getdata_ptr, @intCast(total)));
    
    playdate.system.logToConsole("read %d bytes", offset);
    playdate.system.logToConsole("bytes available %d", http.getBytesAvailable(conn));
    http.getProgress(conn, &read, &total);
    playdate.system.logToConsole("Read: %i, Total: %i", read, total);
    //var avail: i32 = total - read;
    //while (avail > 0) {
    //    avail = @min(avail, 4096);
    //    offset = @intCast(http.read(conn, getdata_ptr+@as(usize,@intCast(read)), @intCast(avail)));
    //    
    //    playdate.system.logToConsole("read %d bytes", offset);
    //    playdate.system.logToConsole("bytes available %d", http.getBytesAvailable(conn));
    //    
    //    //playdate.system.logToConsole("JSON\n%.*s", @as(c_int, avail), getdata_ptr+@as(usize,@intCast(read)));
    //    http.getProgress(conn, &read, &total);
    //    avail = total - read;
    //    playdate.system.logToConsole("Read: %i, Total: %i", read, total);
    //}

    //playdate.system.logToConsole("JSON\n%.*s", @as(c_int,512), getdata_ptr+@as(usize,@intCast(total))-512);
    //playdate.system.logToConsole("JSON\n%s", getdata_ptr+@as(usize,@intCast(total))-128);
    //const f = playdate.file.open("test.json", pdapi.FILE_WRITE);
    //_ = playdate.file.write(f, getdata_ptr, @intCast(total));
    //_ = playdate.file.flush(f);
    //_ = playdate.file.close(f);
    //playdate.system.logToConsole("done");

    var json_decoder = pdapi.JSONDecoder{
        .decodeError = BitmapLibParser.decodeError,
        .willDecodeSublist = BitmapLibParser.willDecodeSublist,
        .shouldDecodeTableValueForKey = null, //shouldDecodeTableValueForKey,
        .didDecodeTableValue = BitmapLibParser.didDecodeTableValue,
        .shouldDecodeArrayValueAtIndex = null, //shouldDecodeArrayValueAtIndex,
        .didDecodeArrayValue = BitmapLibParser.didDecodeArrayValue,
        .didDecodeSublist = BitmapLibParser.didDecodeSublist,
        .userdata = bitmap_parser,
        .returnString = 0,
        .path = null,
    };
    // not sure if the requests ends in a \0
    playdate.system.logToConsole("About to Parse String");
    _ = bitmap_parser.bitlib.playdate.json.decodeString(&json_decoder, getdata_ptr, null);
    playdate.system.logToConsole("Parsed String");
    bitmap_parser.game_state.state = .init;
    bitmap_parser.game_state.bitmap_lib = bitmap_parser.bitlib;
}

const std = @import("std");
const builtin = @import("builtin");
const pdapi = @import("playdate_api_definitions.zig");

const base_types = @import("base_types.zig");

const JsonSource = base_types.JsonSource;
const JsonReader = base_types.JsonReader;
const GlobalState = @import("GlobalState.zig");

const std = @import("std");
const pdapi = @import("playdate_api_definitions.zig");
const playdate = @import("PDapi.zig");

pub const Position = struct {
    x: i16 = 0,
    y: i16 = 0,
};

pub const HttpEndPoint = struct {
    host: [:0]const u8 = "localhost",
    port: i32 = 65433,
    path: [:0]const u8 = "/",
    name: [:0]const u8,

    pub fn getPath(self: *const HttpEndPoint, buf: [:0]u8) [:0]u8 {
        const full_len = self.path.len + self.name.len;
        std.debug.assert(full_len <= buf.len);
        std.mem.copyForwards(u8, buf, self.path);
        std.mem.copyForwards(u8, buf[self.path.len..], self.name);
        buf[full_len] = 0;
        return buf[0..full_len :0];
    }
};

pub const JsonSourceType = enum {
    string,
    file,
    http,
};

pub const JsonFileSrc = struct {
    name: [:0]const u8,
    path: [:0]const u8 = "assets/",
    ext: [:0]const u8 = ".json",

    pub fn getPath(self: *const JsonFileSrc, buf: [:0]u8) [:0]u8 {
        const full_len = self.name.len + self.path.len + self.ext.len;
        std.debug.assert(full_len <= buf.len);
        std.mem.copyForwards(u8, buf, self.path);
        std.mem.copyForwards(u8, buf[self.path.len..], self.name);
        std.mem.copyForwards(u8, buf[self.path.len + self.name.len ..], self.ext);
        buf[full_len] = 0;
        return buf[0..full_len :0];
    }
};

pub const JsonReader = struct {
    json_reader: pdapi.JSONReader,
    file: ?*pdapi.SDFile = null,

    pub fn init(json_path: JsonFileSrc) !JsonReader {
        var buf: [64:0]u8 = @splat(0);
        const path = json_path.getPath(&buf);
        const file = playdate.file.open(path.ptr, pdapi.FILE_READ) orelse return error.FileOpen;
        return .{
            .file = file,
            .json_reader = .{
                .read = @ptrCast(playdate.file.read),
                .userdata = file,
            },
        };
    }
    pub fn deinit(self: *JsonReader) void {
        const status = playdate.file.close(self.file orelse return);
        if (status != 0) playdate.system.logToConsole("ERROR: Failed to close file");
        self.file = null;
    }
};

pub const JsonSource = union(JsonSourceType) {
    string: [:0]const u8,
    file: JsonFileSrc,
    http: HttpEndPoint,
};

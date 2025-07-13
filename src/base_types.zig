const std = @import("std");
const pdapi = @import("playdate_api_definitions.zig");

pub const Position = struct {
    x: i16 = 0,
    y: i16 = 0,
};

pub const JsonSourceType = enum {
    string,
    file,
    //    http,
};

pub const JsonReader = struct {
    json_reader: pdapi.JSONReader,
    file: ?*pdapi.SDFile = null,
    playdate: *const pdapi.PlaydateAPI,

    pub fn init(playdate: *const pdapi.PlaydateAPI, folder: [:0]const u8, name: [:0]const u8) !JsonReader {
        var buf = [_:0]u8{0} ** 64;
        std.mem.copyForwards(u8, &buf, folder);
        std.mem.copyForwards(u8, buf[folder.len..], name);
        std.mem.copyForwards(u8, buf[name.len + folder.len ..], ".json");
        const file = playdate.file.open(&buf, pdapi.FILE_READ) orelse return error.FileOpen;
        return .{
            .playdate = playdate,
            .file = file,
            .json_reader = .{
                .read = @ptrCast(playdate.file.read),
                .userdata = file,
            },
        };
    }
    pub fn deinit(self: *JsonReader) void {
        const status = self.playdate.file.close(self.file orelse return);
        if (status != 0) self.playdate.system.logToConsole("ERROR: Failed to close file");
        self.file = null;
    }
};

pub const JsonSource = union(JsonSourceType) {
    string: [:0]const u8,
    file: [:0]const u8,
    //    http: void,
};

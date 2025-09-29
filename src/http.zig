const enable_debug = false;
const debug = if (builtin.mode == .Debug and enable_debug) true else false;

pub fn readResponse(conn: *pdapi.HTTPConnection) [:0]u8 {
    var read: i32 = 0;
    var total: i32 = 0;

    playdate.network.http.getProgress(conn, &read, &total);

    //const json_size: usize = @intCast(http.getBytesAvailable(conn));
    const json_size: u32 = @intCast(total);
    if (debug) playdate.system.logToConsole("Available Bytes: %i", json_size);

    // We need to pad the size by 1 so we can add a null character to the end of the string
    const getdata_ptr: [*:0]u8 = @ptrCast(@alignCast(playdate.system.realloc(null, @sizeOf(u8) * json_size + 1)));
    getdata_ptr[json_size] = 0;

    if (debug) {
        const err = playdate.network.http.getError(conn);
        if (err != pdapi.PDNetErr.NET_OK) {
            playdate.system.logToConsole("http request complete, err=%i", @intFromEnum(err));
        } else {
            playdate.system.logToConsole("http request complete, %i bytes available", json_size);
        }
    }

    var offset: usize = 0;
    offset = @intCast(playdate.network.http.read(conn, getdata_ptr, @intCast(total)));

    if (debug) {
        playdate.system.logToConsole("read %d bytes", offset);
        playdate.system.logToConsole("bytes available %d", playdate.network.http.getBytesAvailable(conn));
        playdate.network.http.getProgress(conn, &read, &total);
        playdate.system.logToConsole("Read: %i, Total: %i", read, total);
    }
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

    return getdata_ptr[0..json_size :0];
}

const std = @import("std");
const builtin = @import("builtin");
const pdapi = @import("playdate_api_definitions.zig");

const playdate = @import("PDapi.zig");

const base_types = @import("base_types.zig");

const JsonSource = base_types.JsonSource;
const JsonReader = base_types.JsonReader;

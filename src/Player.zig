const enable_debug = false;
const debug = if (builtin.mode == .Debug and enable_debug) true else false;

var global_playdate_ptr: ?*const pdapi.PlaydateAPI = null;

const Player = @This();

sprite: *pdapi.LCDSprite,

bitlib: *const BitmapLib,
id: i16,
duration: i16,
frame_offset: i16,
flip: bool,
resy: i16,

fn playerMovement(sprite: ?*pdapi.LCDSprite) callconv(.C) void {
    const playdate = global_playdate_ptr orelse return;
    const userdata = playdate.sprite.getUserdata(sprite) orelse return;
    const player: *Player = @ptrCast(@alignCast(userdata));

    var x: f32 = undefined;
    var y: f32 = undefined;
    playdate.sprite.getPosition(sprite, &x, &y);

    var current_buttons: pdapi.PDButtons = undefined;
    var pushed_buttons: pdapi.PDButtons = undefined;
    var released_buttons: pdapi.PDButtons = undefined;
    playdate.system.getButtonState(&current_buttons, &pushed_buttons, &released_buttons);

    var dx: f32 = 0.0;
    var dy: f32 = 0.0;
    if (pdapi.BUTTON_LEFT & current_buttons != 0) dx = -2.0;
    if (pdapi.BUTTON_RIGHT & current_buttons != 0) dx = 2.0;
    if (pdapi.BUTTON_UP & current_buttons != 0) dy = -2.0;
    if (pdapi.BUTTON_DOWN & current_buttons != 0) dy = 2.0;

    x += dx;
    y += dy;

    if (dx < 0) player.flip = true;
    if (dx > 0) player.flip = false;
    //if (delta.x != 0 or delta.y != 0) global_state.frame = (global_state.frame + 1) % 18;

    if (dx != 0.0 or dy != 0.0) {
        player.frame_offset = @rem(player.frame_offset + 1, player.duration);
        playdate.sprite.setImage(
            sprite,
            player.bitlib.bitmaps[@intCast(player.id + player.frame_offset)],
            playdate.sprite.getImageFlip(sprite),
        );
        var goalx: f32 = undefined;
        var goaly: f32 = undefined;
        var num_hits: c_int = undefined;
        const hitinfo = playdate.sprite.moveWithCollisions(sprite, x, y, &goalx, &goaly, &num_hits);
        defer {
            _ = playdate.system.realloc(hitinfo, 0);
        }

        //playdate.sprite.moveBy(sprite, dx, dy);
        playdate.sprite.setZIndex(sprite, @as(i16, @intFromFloat(goaly)) + player.resy);
        playdate.sprite.setImageFlip(sprite, if (player.flip) .BitmapFlippedXY else .BitmapFlippedY);
    }
}

fn playerCollider(sprite: ?*pdapi.LCDSprite, other: ?*pdapi.LCDSprite) callconv(.C) pdapi.SpriteCollisionResponseType {
    _ = sprite;
    _ = other;
    //const playdate = global_playdate_ptr orelse return .CollisionTypeFreeze;
    return .CollisionTypeFreeze;
}

pub fn init(playdate: *const pdapi.PlaydateAPI, bitmap_lib: *const BitmapLib, id: i16, duration: i6) !*Player {
    if (global_playdate_ptr == null) {
        global_playdate_ptr = playdate;
    }

    if (id < 0 or id >= bitmap_lib.bitmaps.len) {
        playdate.system.logToConsole("ERROR: Invalid bitmap_id %d, len: %d", id, bitmap_lib.bitmaps.len);
        return error.InvalidPlayer;
    }

    const player: *Player = @ptrCast(@alignCast(playdate.system.realloc(null, @sizeOf(Player))));
    const sprite = playdate.sprite.newSprite() orelse unreachable;

    const bitmap = bitmap_lib.bitmaps[@intCast(id)];
    var img_width: c_int = 0;
    var img_height: c_int = 0;
    playdate.graphics.getBitmapData(bitmap, &img_width, &img_height, null, null, null);

    playdate.sprite.setImage(sprite, bitmap, .BitmapUnflipped);
    // This is required since the flipped arg of setImage doesn't seem to work.
    playdate.sprite.setImageFlip(sprite, .BitmapFlippedY);
    playdate.sprite.setCenter(sprite, 0.0, 0.0);
    playdate.sprite.moveTo(sprite, 0.0, 0.0);
    playdate.sprite.setSize(sprite, @floatFromInt(img_width), @floatFromInt(img_height));
    playdate.sprite.setCollisionsEnabled(sprite, 1);
    playdate.sprite.setCollideRect(sprite, .{ .x = 0.0, .y = 58.0, .width = 64.0, .height = 6.0 });
    playdate.sprite.setCollisionResponseFunction(sprite, playerCollider);
    playdate.sprite.setZIndex(sprite, 0.0);

    player.* = .{
        .resy = @truncate(img_height),
        .sprite = sprite,
        .id = id,
        .duration = duration,
        .flip = false,
        .frame_offset = 0,
        .bitlib = bitmap_lib,
    };

    playdate.sprite.setUserdata(sprite, @ptrCast(player));
    playdate.sprite.setUpdateFunction(sprite, Player.playerMovement);

    return player;
}

pub fn deinit(self: *Player) void {
    const playdate = global_playdate_ptr orelse return;
    playdate.freeSprite(self.sprite);
    playdate.realloc(self, 0);
    self = undefined;
}

const std = @import("std");
const builtin = @import("builtin");
const pdapi = @import("playdate_api_definitions.zig");

const BitmapLib = @import("BitmapLib.zig");
const base_types = @import("base_types.zig");
const Position = base_types.Position;

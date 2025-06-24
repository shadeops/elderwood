// Check commit c8b7982ef98f617300f17d5183b9f869379caca3
// for example of this working
const Position = struct {
    x: i8,
    y: i8,
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
// eventHandler
//  const tiled_bg: *TiledBG = @ptrCast(@alignCast(
//      playdate.system.realloc(null, @sizeOf(TiledBG)),
//  ));
//  tiled_bg.offsetx = 0;
//  tiled_bg.offsety = 0;
//  tiled_bg.tile_map_table = playdate.graphics.loadBitmapTable("assets/images/grid", null).?;
//  tiled_bg.tile_map = playdate.graphics.tilemap.newTilemap().?;
//  playdate.graphics.tilemap.setImageTable(tiled_bg.tile_map, tiled_bg.tile_map_table);

// update_and_render
//    tile_map.updatePos(&global_state.pos, delta);
//
//    tile_map.updateTiles(playdate);
//    playdate.graphics.tilemap.drawAtPoint(
//        tile_map.tile_map,
//        @floatFromInt(global_state.pos.x),
//        @floatFromInt(global_state.pos.y),
//    );
//
//    if (false) {
//        var buffer: [*c]u8 = null;
//        const str_len = playdate.system.formatString(
//            &buffer,
//            "offsetx: %d\noffsety: %d\nposx: %d\nposy: %d",
//            tile_map.offsetx,
//            tile_map.offsety,
//            global_state.pos.x,
//            global_state.pos.y,
//        );
//        if (buffer != null) {
//            defer {
//                _ = playdate.system.realloc(@ptrCast(buffer), 0);
//                buffer = null;
//            }
//            playdate.graphics.fillRect(90, 50, 150, 100, @intFromEnum(clear_color));
//            const pixel_width = playdate.graphics.drawText(@ptrCast(buffer.?), @intCast(str_len), .UTF8Encoding, 100, 50);
//            _ = pixel_width;
//        }
//    }

var pd: *const pd_api_defs.PlaydateAPI = undefined;

pub var system: *const pd_api_defs.PlaydateSys = undefined;
pub var file: *const pd_api_defs.PlaydateFile = undefined;
pub var graphics: *const pd_api_defs.PlaydateGraphics = undefined;
pub var sprite: *const pd_api_defs.PlaydateSprite = undefined;
pub var display: *const pd_api_defs.PlaydateDisplay = undefined;
pub var sound: *const pd_api_defs.PlaydateSound = undefined;
pub var lua: *const pd_api_defs.PlaydateLua = undefined;
pub var json: *const pd_api_defs.PlaydateJSON = undefined;
pub var scoreboards: *const pd_api_defs.PlaydateScoreboards = undefined;
pub var network: *const pd_api_defs.PlaydateNetwork = undefined;

pub fn set_api(playdate: *pd_api_defs.PlaydateAPI) void {
    pd = playdate;
    system = pd.system;
    file = pd.file;
    graphics = pd.graphics;
    sprite = pd.sprite;
    display = pd.display;
    sound = pd.sound;
    lua = pd.lua;
    json = pd.json;
    scoreboards = pd.scoreboards;
    network = pd.network;
}

const std = @import("std");
const builtin = @import("builtin");
const pd_api_defs = @import("playdate_api_definitions.zig");

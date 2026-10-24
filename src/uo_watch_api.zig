//! TownWatch.codex's face for a host (src/gen/uo_watch.zig, its library): a
//! town kept between calls. Texts come back UTF-8 on the Codex heap: a host
//! copies them out before it gives the heap back past them.

const lib = @import("gen/uo_watch.zig");

pub const api = struct {
    pub const Watch = lib.TownWatch;

    pub const heapGive = lib.cx.heapGive;
    pub const heapUsed = lib.cx.heapUsed;
    pub const heapMark = lib.cx.heapMark;
    pub const heapBack = lib.cx.heapBack;

    /// The town, built: everything it keeps is below the frontier after.
    pub fn new() Watch {
        return lib.tw_new(0);
    }

    /// Why there is no town, or "" when there is one.
    pub fn problem(w: Watch) []const u8 {
        return lib.cx.utf8(w.problem);
    }

    /// The town brought to `seconds` of game time; false when a step failed.
    pub fn tick(w: Watch, seconds: i64) bool {
        return lib.tw_tick(w, seconds);
    }

    /// Where everyone is now, as JSON.
    pub fn json(w: Watch, seconds: i64) []const u8 {
        return lib.cx.utf8(lib.tw_json(w, seconds));
    }

    /// The map's bounds and its shops, as JSON.
    pub fn mapJson(w: Watch) []const u8 {
        return lib.cx.utf8(lib.tw_map_json(w));
    }
};

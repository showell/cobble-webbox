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

    /// A player in seat `slot` (0 to 4), named `name` (ASCII): its body's
    /// serial, or -1. Lasting: no heap mark may be taken back past it.
    pub fn join(w: Watch, slot: i64, name: []const u8) error{NotAscii}!i64 {
        return lib.tw_join(w, slot, try lib.cx.fromAscii(name));
    }

    /// The seat empty again; its body stays where it stands.
    pub fn leave(w: Watch, slot: i64) bool {
        return lib.tw_leave(w, slot);
    }

    /// The seat's body sent to (x, y); false off the map or with no body.
    pub fn goal(w: Watch, slot: i64, x: i64, y: i64) bool {
        return lib.tw_goal(w, slot, x, y);
    }

    /// What the townsfolk say to the players now, as a JSON array of
    /// `{who, to, text}`.
    pub fn greet(w: Watch, seconds: i64) []const u8 {
        return lib.cx.utf8(lib.tw_greet(w, seconds));
    }

    /// What the seat's player says (ASCII), heard by the townsfolk near it,
    /// at `at` (the host's clock in hundredths of a second): JSON of the
    /// lines said back and the handler's note. Lasting (a keeper's quote is
    /// kept): no heap mark may be taken back past it.
    pub fn say(w: Watch, slot: i64, words: []const u8, at: i64) error{NotAscii}![]const u8 {
        return lib.cx.utf8(lib.tw_say(w, slot, try lib.cx.fromAscii(words), at));
    }

    /// The prices a keeper quoted the seat's player, as a JSON array.
    pub fn offers(w: Watch, slot: i64) []const u8 {
        return lib.cx.utf8(lib.tw_offers(w, slot));
    }

    /// The seat's player buys `quantity` of offer `i`: JSON of whether a
    /// sale was made and what the keeper said. Lasting, as `say`.
    pub fn buy(w: Watch, slot: i64, i: i64, quantity: i64, at: i64) []const u8 {
        return lib.cx.utf8(lib.tw_buy(w, slot, i, quantity, at));
    }

    /// Resident `person` (1 to 3) sent on an errand for a game hour: action
    /// 0 home, 1 to work, 4 to the tavern, 3 to keeper `keeper`'s shop. 0
    /// sent, below 0 refused (tl-direct's answer). Lasting.
    pub fn errand(w: Watch, person: i64, action: i64, keeper: i64) i64 {
        return lib.tw_errand(w, person, action, keeper);
    }

    /// Damian's own checks of the town (TLC1) and of its currency.
    pub fn valid(w: Watch) bool {
        return lib.tw_valid(w);
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

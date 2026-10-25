//! uoaix on webbox: a live town, apps/uoaix/TownWatch.codex (Damian's
//! townsfolk, shops and trade, compiled to Zig, src/gen/uo_watch.zig), kept
//! and ticked between requests, and the players who join it.
//!
//!   GET  /uo/town/           the watcher's page (web/uo-town.html)
//!   GET  /uo/town/map        the map's bounds and shops, JSON, once
//!   GET  /uo/town/now        where everyone is, JSON
//!   GET  /uo/town/events     the same, each tick, as a stream
//!   POST /uo/town/speed?x=N  game seconds a real one: 0 (paused, as it starts), 60, 120, 600 or 1200
//!   POST /uo/town/join?name=Ann       a seat: `{"token":..,"seat":n}`, 503 when all five are taken
//!   POST /uo/town/go?t=TOKEN&x=&y=    the seat's body sent walking there
//!   POST /uo/town/say?t=TOKEN&words=  heard by the townsfolk near it; "vendor buy" to a keeper
//!   GET  /uo/town/offers?t=TOKEN      the prices a keeper quoted it
//!   POST /uo/town/buy?t=TOKEN&i=&n=   buy n of offer i
//!   POST /uo/town/errand?t=TOKEN&who=1..3&do=home|work|tavern   a resident sent there for a game hour
//!   POST /uo/town/reset      start over: a new town at six, paused, every seat free
//!
//! The town lives below its heap's mark; each tick's scratch is given back.
//! A player's join, words, purchase and errand change what the town keeps,
//! so theirs is not. The host's request turns keep all of it one at a
//! time, `between` included. The feed carries the server's own facts and a
//! log of what each request ran, for a demo whose subject is the server.

const std = @import("std");
const Io = @import("host_io").Io;
const webbox = @import("webbox");
const http = webbox.http;
const watch = @import("uo_watch_api.zig").api;

pub const prefix = "/uo";

/// The Codex heap's region: the kept town uses about 18 MB, its players'
/// joins, words and purchases a little more each.
const heap_region: usize = 128 * 1024 * 1024;

/// The town's clock: a tick a quarter second, from six in the morning, at
/// `speed` game seconds a real one (120: a game day in 12 minutes). A
/// change of speed starts the clock again from where it is, so the town's
/// time never jumps or goes back.
const tick_ns: i96 = 250 * std.time.ns_per_ms;
const game_start: i64 = 6 * 3600;
const speeds = [_]i64{ 0, 60, 120, 600, 1200 };
var speed: i64 = 0;

/// Where the server runs, as the demo says it.
const host_kind = if (@import("builtin").os.tag == .freestanding) "bare metal (the unikernel)" else "Linux";
var ticks: u64 = 0;
/// Which town this is: a start over makes the next, and every page that
/// sees it change loads the new one.
var epoch: u64 = 1;
/// The Codex heap's region, zeroed again for a new town: the runtime reads
/// fresh memory as zero, as bare metal's boot leaves it.
var region: []align(4096) u8 = &.{};
var last_tick_us: i64 = 0;

/// What each request ran since the last feed, JSON objects joined by
/// commas: the next feed carries them as "log".
var log: std.ArrayList(u8) = .empty;

fn note(comptime fmt: []const u8, args: anytype) void {
    var buf: [400]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..];
    if (log.items.len > 0) log.append(gpa, ',') catch return;
    log.print(gpa, "{{\"text\":{f}}}", .{std.json.fmt(text, .{})}) catch return;
}

const events_key = "uo-town";

pub const StartReport = struct { problem: []const u8 };

var kept: watch.Watch = undefined;
var game_seconds: i64 = game_start;
/// The game time the clock last started from, and when, on the awake
/// clock; null before the first `between`.
var base_seconds: i64 = game_start;
var base_ns: ?i96 = null;
var next_tick_ns: i96 = 0;
/// The latest `watch.json`, copied out of the Codex heap.
var now_json: std.ArrayList(u8) = .empty;
var map_json: []const u8 = "";
var gpa: std.mem.Allocator = undefined;
var problem: []const u8 = "";
/// Whether `setup` has made the town: a site's `between` may be called
/// before (angry-gopher's script tests call it with no setup).
var set_up = false;

/// The town's five seats (TownWatch's, the account's character slots), each
/// held by the token its player was given; a seat quiet for `seat_idle_ns`
/// is free again, its body left where it stands.
const Seat = struct { token: [16]u8 = undefined, held: bool = false, last_ns: i96 = 0, name: [16]u8 = undefined, name_len: usize = 0 };
var seats: [5]Seat = @splat(.{});
const seat_idle_ns: i96 = 120 * std.time.ns_per_s;

/// What players said and were answered since the last tick, JSON objects
/// joined by commas: the next tick's feed carries them as "spoken".
var spoken: std.ArrayList(u8) = .empty;

pub fn setup(io: Io, base: std.mem.Allocator, roots: ?webbox.site.Roots) !StartReport {
    _ = roots;
    gpa = base;
    region = try base.alignedAlloc(u8, .fromByteUnits(4096), heap_region);
    @memset(region, 0);
    watch.heapGive(region);
    try build(io);
    if (problem.len > 0) return .{ .problem = problem };
    set_up = true;
    const mark = watch.heapMark();
    map_json = try base.dupe(u8, watch.mapJson(kept));
    watch.heapBack(mark);
    return .{ .problem = "" };
}

/// A town, new: built on a fresh Codex heap, ticked once at six (the shops
/// shut or open by their hours before anyone sees it), paused, its seats
/// free, its feed made.
fn build(io: Io) !void {
    kept = watch.new();
    problem = try gpa.dupe(u8, watch.problem(kept));
    if (problem.len > 0) return;
    if (!watch.tick(kept, game_start)) {
        problem = "the town's first tick failed";
        return;
    }
    game_seconds = game_start;
    base_seconds = game_start;
    base_ns = null;
    speed = 0;
    ticks = 0;
    last_tick_us = 0;
    seats = @splat(.{});
    spoken.clearRetainingCapacity();
    try advance(io, game_start);
}

/// Start over: the town given back with its whole heap and a new one built.
/// Every page sees the epoch change and loads the new town.
fn reset(req: *std.http.Server.Request, io: Io) !void {
    if (req.head.method != .POST) return http.methodNotAllowed(req, .POST);
    watch.heapReset();
    @memset(region, 0);
    epoch += 1;
    log.clearRetainingCapacity();
    try build(io);
    if (problem.len > 0) return req.respond(problem, .{ .status = .service_unavailable, .extra_headers = &.{http.plain_ct} });
    note("start over: the Codex heap given back whole and tw-new builds a new town, paused at six; every seat free", .{});
    return req.respond("", .{ .status = .no_content });
}

/// The town brought to `seconds` (unchanged when it is there), and the feed
/// made again: the speed every watcher shares, the server's facts, what the
/// townsfolk said to the players, what players said, and what each request
/// ran.
fn advance(io: Io, seconds: i64) !void {
    if (seconds > game_seconds) {
        const t0 = Io.Clock.now(.awake, io).nanoseconds;
        if (!watch.tick(kept, seconds)) return error.TownStepFailed;
        last_tick_us = @intCast(@divFloor(Io.Clock.now(.awake, io).nanoseconds - t0, std.time.ns_per_us));
        ticks += 1;
        game_seconds = seconds;
    }
    const mark = watch.heapMark();
    defer watch.heapBack(mark);
    now_json.clearRetainingCapacity();
    const heap = watch.heapUsed();
    const said = watch.greet(kept, game_seconds);
    const town_json = watch.json(kept, game_seconds);
    try now_json.print(gpa, "{{\"epoch\":{d},\"speed\":{d},\"server\":{{\"host\":\"{s}\",\"ticks\":{d},\"tick_us\":{d},\"heap\":{d}}},\"said\":{s},\"spoken\":[{s}],\"log\":[{s}],", .{ epoch, speed, host_kind, ticks, last_tick_us, heap, said, spoken.items, log.items });
    spoken.clearRetainingCapacity();
    log.clearRetainingCapacity();
    try now_json.appendSlice(gpa, town_json[1..]);
}

pub fn between(io: Io, now: webbox.site.Now, bus: *webbox.bus.Bus) webbox.site.Wake {
    if (!set_up or problem.len > 0) return .idle;
    const t0 = base_ns orelse blk: {
        base_ns = now.awake_ns;
        next_tick_ns = now.awake_ns;
        break :blk now.awake_ns;
    };
    if (now.awake_ns < next_tick_ns) return .{ .at = next_tick_ns };
    for (&seats, 0..) |*seat, i| if (seat.held and now.awake_ns - seat.last_ns > seat_idle_ns) {
        seat.held = false;
        _ = watch.leave(kept, @intCast(i));
        note("{s} left (quiet two minutes): tw-leave frees seat {d}, the body stays where it stands", .{ seat.name[0..seat.name_len], i });
    };
    const target: i64 = base_seconds + @as(i64, @intCast(@divFloor((now.awake_ns - t0) * speed, std.time.ns_per_s)));
    // A tick when the clock has moved; a feed too when only a request has
    // (paused, a join or words are still news to every watcher).
    if (target > game_seconds or log.items.len > 0 or spoken.items.len > 0) {
        advance(io, target) catch |e| std.debug.panic("uo town: {s} at game second {d}", .{ @errorName(e), target });
        bus.publish(events_key, now_json.items);
    }
    next_tick_ns = webbox.site.periodAfter(next_tick_ns, tick_ns, now.awake_ns);
    return .{ .at = next_tick_ns };
}

pub fn bodyLimit(path: []const u8) u64 {
    _ = path;
    return 0;
}

const json_ct: std.http.Header = .{ .name = "content-type", .value = "application/json; charset=utf-8" };

/// A seat for `name` (letters, 1 to 16): its body at the town's entrance,
/// or the body its last player left. Lasting: the Codex heap keeps it.
fn join(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator, whole: []const u8) !void {
    if (req.head.method != .POST) return http.methodNotAllowed(req, .POST);
    const name = http.queryValue(whole, "name") orelse "";
    const fine = name.len >= 1 and name.len <= 16 and for (name) |c| {
        if (!std.ascii.isAlphabetic(c)) break false;
    } else true;
    if (!fine) return req.respond("a name is 1 to 16 letters\n", .{ .status = .bad_request, .extra_headers = &.{http.plain_ct} });
    const slot = for (seats, 0..) |seat, i| {
        if (!seat.held) break i;
    } else return req.respond("{\"error\":\"the town is full (5)\"}", .{ .status = .service_unavailable, .extra_headers = &.{json_ct} });
    if ((watch.join(kept, @intCast(slot), name) catch -1) <= 0)
        return req.respond("{\"error\":\"no body for the seat\"}", .{ .status = .internal_server_error, .extra_headers = &.{json_ct} });
    var bytes: [8]u8 = undefined;
    io.random(&bytes);
    const seat = &seats[slot];
    _ = std.fmt.bufPrint(&seat.token, "{x}", .{bytes}) catch unreachable;
    seat.held = true;
    seat.last_ns = Io.Clock.now(.awake, io).nanoseconds;
    @memcpy(seat.name[0..name.len], name);
    seat.name_len = name.len;
    note("join {s}: tw-join gives seat {d} a body at the town's entrance, bound to a character slot, with a pack and a purse", .{ name, slot });
    return req.respond(try std.fmt.allocPrint(alloc, "{{\"token\":\"{s}\",\"seat\":{d}}}", .{ &seat.token, slot }), .{ .extra_headers = &.{json_ct} });
}

/// The seat holding the request's token `t`, its quiet time restarted; null
/// when no seat holds it.
fn seatOf(io: Io, whole: []const u8) ?usize {
    const t = http.queryValue(whole, "t") orelse return null;
    for (&seats, 0..) |*seat, i| if (seat.held and std.mem.eql(u8, &seat.token, t)) {
        seat.last_ns = Io.Clock.now(.awake, io).nanoseconds;
        return i;
    };
    return null;
}

/// The host's clock for the townsfolk's quotes: hundredths of a second, the
/// PIT's rate, which a keeper's quote lasts a minute of.
fn ticksNow(io: Io) i64 {
    return @intCast(@divFloor(Io.Clock.now(.awake, io).nanoseconds, 10 * std.time.ns_per_ms));
}

/// The handler's note in a TownWatch answer, or `none` when it has none.
fn noteOf(answer: []const u8, none: []const u8) []const u8 {
    const key = "\"note\":\"";
    const at = std.mem.indexOf(u8, answer, key) orelse return none;
    const rest = answer[at + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return none;
    return if (end == 0) none else rest[0..end];
}

/// `answer` (TownWatch's `{heard, ...}`) in "spoken" for every watcher,
/// after the player's own words when it spoke.
fn tellAll(slot: usize, words: ?[]const u8, answer: []const u8) !void {
    if (words) |said| {
        if (spoken.items.len > 0) try spoken.append(gpa, ',');
        const name = seats[slot].name[0..seats[slot].name_len];
        try spoken.print(gpa, "{{\"who\":{f},\"to\":\"\",\"text\":{f}}}", .{ std.json.fmt(name, .{}), std.json.fmt(said, .{}) });
    }
    const heard = std.mem.indexOf(u8, answer, "\"heard\":[") orelse return;
    const from = heard + "\"heard\":[".len;
    const to = std.mem.indexOfPos(u8, answer, from, "]") orelse return;
    if (to == from) return;
    if (spoken.items.len > 0) try spoken.append(gpa, ',');
    try spoken.appendSlice(gpa, answer[from..to]);
}

/// The seat's player speaks: the townsfolk near it hear it. Lasting (a
/// keeper's quote is kept), so the Codex heap is not taken back.
fn say(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator, whole: []const u8) !void {
    if (req.head.method != .POST) return http.methodNotAllowed(req, .POST);
    const slot = seatOf(io, whole) orelse return req.respond("no seat holds that token\n", .{ .status = .forbidden, .extra_headers = &.{http.plain_ct} });
    const words = http.formDecode(alloc, http.queryValue(whole, "words") orelse "") catch "";
    const fine = words.len >= 1 and words.len <= 120 and for (words) |c| {
        if (c < 32 or c > 126) break false;
    } else true;
    if (!fine) return req.respond("words are 1 to 120 printable ASCII characters\n", .{ .status = .bad_request, .extra_headers = &.{http.plain_ct} });
    const answer = try alloc.dupe(u8, try watch.say(kept, @intCast(slot), words, ticksNow(io)));
    try tellAll(slot, words, answer);
    note("say \"{s}\": tw-say hands the client's speech packet to ns-handler-at; {s}", .{ words, noteOf(answer, "nobody near answers") });
    return req.respond(answer, .{ .extra_headers = &.{json_ct} });
}

/// The prices a keeper quoted the seat's player: read only, so the Codex
/// heap goes back.
fn offers(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator, whole: []const u8) !void {
    if (req.head.method != .GET) return http.methodNotAllowed(req, .GET);
    const slot = seatOf(io, whole) orelse return req.respond("no seat holds that token\n", .{ .status = .forbidden, .extra_headers = &.{http.plain_ct} });
    const mark = watch.heapMark();
    defer watch.heapBack(mark);
    return req.respond(try alloc.dupe(u8, watch.offers(kept, @intCast(slot))), .{ .extra_headers = &.{json_ct} });
}

/// The seat's player buys `n` of offer `i`. Lasting, as `say`.
fn buy(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator, whole: []const u8) !void {
    if (req.head.method != .POST) return http.methodNotAllowed(req, .POST);
    const slot = seatOf(io, whole) orelse return req.respond("no seat holds that token\n", .{ .status = .forbidden, .extra_headers = &.{http.plain_ct} });
    const i = std.fmt.parseInt(i64, http.queryValue(whole, "i") orelse "", 10) catch -1;
    const n = std.fmt.parseInt(i64, http.queryValue(whole, "n") orelse "1", 10) catch 0;
    const answer = try alloc.dupe(u8, watch.buy(kept, @intCast(slot), i, n, ticksNow(io)));
    try tellAll(slot, null, answer);
    note("buy offer {d}: tw-buy sends the client's cart packet to gv-handle-at; {s}", .{ i, noteOf(answer, "no quote stands") });
    return req.respond(answer, .{ .extra_headers = &.{json_ct} });
}

/// The seat's player sends a resident on an errand for a game hour. Lasting.
fn errand(req: *std.http.Server.Request, io: Io, whole: []const u8) !void {
    if (req.head.method != .POST) return http.methodNotAllowed(req, .POST);
    const slot = seatOf(io, whole) orelse return req.respond("no seat holds that token\n", .{ .status = .forbidden, .extra_headers = &.{http.plain_ct} });
    const who = std.fmt.parseInt(i64, http.queryValue(whole, "who") orelse "", 10) catch 0;
    const Errand = struct { word: []const u8, action: i64, said: []const u8 };
    const errands = [_]Errand{ .{ .word = "home", .action = 0, .said = "go home" }, .{ .word = "work", .action = 1, .said = "go to work" }, .{ .word = "tavern", .action = 4, .said = "go to the tavern" } };
    const do = http.queryValue(whole, "do") orelse "";
    const e = for (errands) |x| {
        if (std.mem.eql(u8, x.word, do)) break x;
    } else return req.respond("an errand is home, work or tavern\n", .{ .status = .bad_request, .extra_headers = &.{http.plain_ct} });
    const answer = watch.errand(kept, who, e.action, 0);
    note("errand, resident {d} to {s}: tw-errand calls tl-direct, which answers {d} ({s})", .{ who, e.word, answer, if (answer >= 0) "sent for a game hour" else "refused" });
    if (answer < 0) return req.respond("{\"sent\":false}", .{ .extra_headers = &.{json_ct} });
    // Every watcher hears the player send the resident (by name, from the feed).
    if (std.mem.indexOf(u8, now_json.items, "\"people\":[")) |at| {
        var names = std.mem.splitSequence(u8, now_json.items[at..], "{\"name\":\"");
        _ = names.next();
        var n: i64 = 1;
        while (names.next()) |rest| : (n += 1) if (n == who) {
            const name = rest[0 .. std.mem.indexOfScalar(u8, rest, '"') orelse 0];
            if (spoken.items.len > 0) try spoken.append(gpa, ',');
            const player = seats[slot].name[0..seats[slot].name_len];
            try spoken.print(gpa, "{{\"who\":{f},\"to\":{f},\"text\":{f}}}", .{ std.json.fmt(player, .{}), std.json.fmt(name, .{}), std.json.fmt(e.said, .{}) });
            break;
        };
    }
    return req.respond("{\"sent\":true}", .{ .extra_headers = &.{json_ct} });
}

/// The seat holding token `t` sends its body to (x, y).
fn go(req: *std.http.Server.Request, io: Io, whole: []const u8) !void {
    if (req.head.method != .POST) return http.methodNotAllowed(req, .POST);
    const slot = seatOf(io, whole) orelse return req.respond("no seat holds that token\n", .{ .status = .forbidden, .extra_headers = &.{http.plain_ct} });
    const x = std.fmt.parseInt(i64, http.queryValue(whole, "x") orelse "", 10) catch -1;
    const y = std.fmt.parseInt(i64, http.queryValue(whole, "y") orelse "", 10) catch -1;
    if (!watch.goal(kept, @intCast(slot), x, y)) return req.respond("not a place on the map\n", .{ .status = .bad_request, .extra_headers = &.{http.plain_ct} });
    note("go to ({d}, {d}): tw-goal; each tick tw-tick steps the body by rte-toward, the townsfolk's own router", .{ x, y });
    return req.respond("", .{ .status = .no_content });
}

/// A new speed from now on: the clock started again from the town's time.
fn setSpeed(req: *std.http.Server.Request, io: Io, whole: []const u8) !void {
    if (req.head.method != .POST) return http.methodNotAllowed(req, .POST);
    const x = std.fmt.parseInt(i64, http.queryValue(whole, "x") orelse "", 10) catch -1;
    if (std.mem.indexOfScalar(i64, &speeds, x) == null)
        return req.respond("speed is 0, 60, 120, 600 or 1200 game seconds a real one\n", .{ .status = .bad_request, .extra_headers = &.{http.plain_ct} });
    base_seconds = game_seconds;
    base_ns = Io.Clock.now(.awake, io).nanoseconds;
    if (x != speed) note("{s}: the town's clock runs at {d} game seconds a real one; each 250 ms between requests, tw-tick advances it", .{ if (x == 0) "paused" else if (speed == 0) "started" else "pace", x });
    speed = x;
    return req.respond("", .{ .status = .no_content });
}

pub fn routes(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator, bus: *webbox.bus.Bus) !void {
    const whole = try http.target(req, alloc);
    const path = http.pathUnder(http.pathOf(whole), prefix) orelse return http.notFound(req);
    if (std.mem.eql(u8, path, "/town")) return http.redirect(req, prefix ++ "/town/");
    if (std.mem.eql(u8, path, "/town/events")) return webbox.sse.forward(req, bus, events_key);
    if (std.mem.eql(u8, path, "/town/speed")) return setSpeed(req, io, whole);
    if (std.mem.eql(u8, path, "/town/join")) return join(req, io, alloc, whole);
    if (std.mem.eql(u8, path, "/town/go")) return go(req, io, whole);
    if (std.mem.eql(u8, path, "/town/say")) return say(req, io, alloc, whole);
    if (std.mem.eql(u8, path, "/town/offers")) return offers(req, io, alloc, whole);
    if (std.mem.eql(u8, path, "/town/buy")) return buy(req, io, alloc, whole);
    if (std.mem.eql(u8, path, "/town/errand")) return errand(req, io, whole);
    if (std.mem.eql(u8, path, "/town/reset")) return reset(req, io);
    if (req.head.method != .GET) return http.methodNotAllowed(req, .GET);
    if (std.mem.eql(u8, path, "/town/")) return req.respond(@embedFile("uo_town_page"), .{ .extra_headers = &.{http.html_ct} });
    if (std.mem.eql(u8, path, "/town/map") or std.mem.eql(u8, path, "/town/now")) {
        if (problem.len > 0) return req.respond(problem, .{ .status = .service_unavailable, .extra_headers = &.{http.plain_ct} });
        const body = if (std.mem.eql(u8, path, "/town/map")) map_json else now_json.items;
        return req.respond(body, .{ .extra_headers = &.{json_ct} });
    }
    return http.notFound(req);
}

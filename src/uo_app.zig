//! uoaix on webbox: two of apps/uoaix/proofs/, each run by a request and
//! answered as text (its lines as its `.expected` has them), and a live
//! town, apps/uoaix/TownWatch.codex, kept and ticked between requests.
//!
//!   GET /uo/vendor-proof    GameVendorReplay (src/gen/uo.zig)
//!   GET /uo/town-proof      TownLiveProof (src/gen/uo_town.zig)
//!   GET /uo/town/           the watcher's page (web/uo-town.html)
//!   GET /uo/town/map        the map's bounds and shops, JSON, once
//!   GET /uo/town/now        where everyone is, JSON
//!   GET /uo/town/events     the same, each tick, as a stream
//!   POST /uo/town/speed?x=N  game seconds a real one: 60, 120, 600 or 1200
//!   POST /uo/town/join?name=Ann       a seat: `{"token":..,"seat":n}`, 503 when all five are taken
//!   POST /uo/town/go?t=TOKEN&x=&y=    the seat's body sent walking there
//!   POST /uo/town/say?t=TOKEN&words=  heard by the townsfolk near it; "vendor buy" to a keeper
//!   GET  /uo/town/offers?t=TOKEN      the prices a keeper quoted it
//!   POST /uo/town/buy?t=TOKEN&i=&n=   buy n of offer i
//!   POST /uo/town/errand?t=TOKEN&who=1..3&do=home|work|tavern   a resident sent there for a game hour
//!
//! A proof's run starts its Codex heap from its base, so it costs nothing
//! that lasts. The town lives below its heap's mark; each tick's scratch
//! is given back. The host's request turns keep all of it one at a time,
//! `between` included.

const std = @import("std");
const Io = @import("host_io").Io;
const webbox = @import("webbox");
const http = webbox.http;
const vendor = @import("uo_api.zig").vendor;
const town = @import("uo_api.zig").town;
const watch = @import("uo_watch_api.zig").api;

pub const prefix = "/uo";

/// Each proof's Codex heap region: the vendor proof uses about 75 MB, the
/// town proof about 24 MB, the kept town about 18 MB.
const heap_region: usize = 128 * 1024 * 1024;

/// The town's clock: a tick a quarter second, from six in the morning, at
/// `speed` game seconds a real one (120: a game day in 12 minutes). A
/// change of speed starts the clock again from where it is, so the town's
/// time never jumps or goes back.
const tick_ns: i96 = 250 * std.time.ns_per_ms;
const game_start: i64 = 6 * 3600;
const speeds = [_]i64{ 60, 120, 600, 1200 };
var speed: i64 = 120;

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
    _ = io;
    _ = roots;
    gpa = base;
    inline for (.{ vendor, town, watch }) |lib| {
        const region = try base.alignedAlloc(u8, .fromByteUnits(4096), heap_region);
        @memset(region, 0);
        lib.heapGive(region);
    }
    kept = watch.new();
    problem = try base.dupe(u8, watch.problem(kept));
    if (problem.len > 0) return .{ .problem = problem };
    const mark = watch.heapMark();
    map_json = try base.dupe(u8, watch.mapJson(kept));
    watch.heapBack(mark);
    try advance(game_start);
    return .{ .problem = "" };
}

/// The town brought to `seconds`, and its JSON kept.
fn advance(seconds: i64) !void {
    if (!watch.tick(kept, seconds)) return error.TownStepFailed;
    game_seconds = seconds;
    const mark = watch.heapMark();
    defer watch.heapBack(mark);
    now_json.clearRetainingCapacity();
    // The town's JSON, with the speed every watcher shares and what the
    // townsfolk said to the players this tick.
    const said = watch.greet(kept, seconds);
    const town_json = watch.json(kept, seconds);
    try now_json.print(gpa, "{{\"speed\":{d},\"said\":{s},\"spoken\":[{s}],", .{ speed, said, spoken.items });
    spoken.clearRetainingCapacity();
    try now_json.appendSlice(gpa, town_json[1..]);
}

pub fn between(io: Io, now: webbox.site.Now, bus: *webbox.bus.Bus) webbox.site.Wake {
    _ = io;
    if (problem.len > 0) return .idle;
    const t0 = base_ns orelse blk: {
        base_ns = now.awake_ns;
        next_tick_ns = now.awake_ns;
        break :blk now.awake_ns;
    };
    if (now.awake_ns < next_tick_ns) return .{ .at = next_tick_ns };
    for (&seats, 0..) |*seat, i| if (seat.held and now.awake_ns - seat.last_ns > seat_idle_ns) {
        seat.held = false;
        _ = watch.leave(kept, @intCast(i));
    };
    const target: i64 = base_seconds + @as(i64, @intCast(@divFloor((now.awake_ns - t0) * speed, std.time.ns_per_s)));
    if (target > game_seconds) {
        advance(target) catch |e| std.debug.panic("uo town: {s} at game second {d}", .{ @errorName(e), target });
        bus.publish(events_key, now_json.items);
    }
    next_tick_ns = webbox.site.periodAfter(next_tick_ns, tick_ns, now.awake_ns);
    return .{ .at = next_tick_ns };
}

pub fn bodyLimit(path: []const u8) u64 {
    _ = path;
    return 0;
}

var printed: std.ArrayList(u8) = .empty;
var printed_alloc: std.mem.Allocator = undefined;

fn sink(line: []const u8) void {
    printed.appendSlice(printed_alloc, line) catch @panic("uo: out of memory for the proof's lines");
    printed.append(printed_alloc, '\n') catch @panic("uo: out of memory for the proof's lines");
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
    return req.respond("", .{ .status = .no_content });
}

/// A new speed from now on: the clock started again from the town's time.
fn setSpeed(req: *std.http.Server.Request, io: Io, whole: []const u8) !void {
    if (req.head.method != .POST) return http.methodNotAllowed(req, .POST);
    const x = std.fmt.parseInt(i64, http.queryValue(whole, "x") orelse "", 10) catch 0;
    if (std.mem.indexOfScalar(i64, &speeds, x) == null)
        return req.respond("speed is 60, 120, 600 or 1200 game seconds a real one\n", .{ .status = .bad_request, .extra_headers = &.{http.plain_ct} });
    base_seconds = game_seconds;
    base_ns = Io.Clock.now(.awake, io).nanoseconds;
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
    if (req.head.method != .GET) return http.methodNotAllowed(req, .GET);
    if (std.mem.eql(u8, path, "/town/")) return req.respond(@embedFile("uo_town_page"), .{ .extra_headers = &.{http.html_ct} });
    if (std.mem.eql(u8, path, "/town/map") or std.mem.eql(u8, path, "/town/now")) {
        if (problem.len > 0) return req.respond(problem, .{ .status = .service_unavailable, .extra_headers = &.{http.plain_ct} });
        const body = if (std.mem.eql(u8, path, "/town/map")) map_json else now_json.items;
        return req.respond(body, .{ .extra_headers = &.{json_ct} });
    }
    const run = if (std.mem.eql(u8, path, "/vendor-proof"))
        &vendor.runProof
    else if (std.mem.eql(u8, path, "/town-proof"))
        &town.runProof
    else
        return http.notFound(req);
    printed = .empty;
    printed_alloc = alloc;
    run(sink);
    return req.respond(printed.items, .{ .extra_headers = &.{http.plain_ct} });
}

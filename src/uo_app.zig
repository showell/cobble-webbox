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

/// The town's clock: a tick a quarter second, 120 game seconds a real one
/// (a game day in 12 minutes), from six in the morning.
const tick_ns: i96 = 250 * std.time.ns_per_ms;
const game_speed: i96 = 120;
const game_start: i64 = 6 * 3600;

const events_key = "uo-town";

pub const StartReport = struct { problem: []const u8 };

var kept: watch.Watch = undefined;
var game_seconds: i64 = game_start;
/// When the clock's game_start was, on the awake clock; null before the
/// first `between`.
var started_ns: ?i96 = null;
var next_tick_ns: i96 = 0;
/// The latest `watch.json`, copied out of the Codex heap.
var now_json: std.ArrayList(u8) = .empty;
var map_json: []const u8 = "";
var gpa: std.mem.Allocator = undefined;
var problem: []const u8 = "";

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
    try now_json.appendSlice(gpa, watch.json(kept, seconds));
}

pub fn between(io: Io, now: webbox.site.Now, bus: *webbox.bus.Bus) webbox.site.Wake {
    _ = io;
    if (problem.len > 0) return .idle;
    const t0 = started_ns orelse blk: {
        started_ns = now.awake_ns;
        next_tick_ns = now.awake_ns;
        break :blk now.awake_ns;
    };
    if (now.awake_ns < next_tick_ns) return .{ .at = next_tick_ns };
    const target: i64 = game_start + @as(i64, @intCast(@divFloor((now.awake_ns - t0) * game_speed, std.time.ns_per_s)));
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

pub fn routes(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator, bus: *webbox.bus.Bus) !void {
    _ = io;
    const whole = try http.target(req, alloc);
    const path = http.pathUnder(http.pathOf(whole), prefix) orelse return http.notFound(req);
    if (std.mem.eql(u8, path, "/town")) return http.redirect(req, prefix ++ "/town/");
    if (std.mem.eql(u8, path, "/town/events")) return webbox.sse.forward(req, bus, events_key);
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

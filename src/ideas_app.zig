//! Idea Forge (Cobblestone's apps/ideas), served by webbox
//! (`webbox.site.Site(App)`): IdeaWeb.codex's routes, compiled to Zig
//! (src/gen/ideas.zig), with IdeaServer.codex's network shell, and the
//! bridge apps/ideas/run.ps1 put in front of it, replaced by this file.
//!
//!   GET /, /index.html   the page: IdeaPage.codex as Cobblestone's HTML plug
//!                        built it (web/idea-forge.html, compiled in), as
//!                        run.ps1's bridge served it
//!   everything else      IdeaWeb's `idea-route-at`, which answers it whole
//!                        (README.md in apps/ideas: `/offer`, `/claim`,
//!                        `/claims`, `/idea`, `/api/health`)
//!
//! What IdeaServer told IdeaWeb, this host tells it:
//!
//!   the caller   `X-Forwarded-For` when the request carries one, else the
//!                `who` query parameter, else `the-proxy` (`resolve-who`)
//!   the day      whole days since the house opened (`current-day`: PIT
//!                ticks since boot, a day's worth at a time)
//!
//! The state, IdeaWeb's `IdeaState`, is threaded from request to request
//! as IdeaServer threaded it, in memory: the house's reservations live as
//! long as it does.

const std = @import("std");
const Io = @import("host_io").Io;
const webbox = @import("webbox");
const http = webbox.http;
const ideas = @import("ideas_api.zig").api;
const onBigStack = @import("stack.zig").onBigStack;

/// One handler runs at a time (webbox's hosts), so it is shared plainly.
var state: ideas.State = undefined;
/// When the house opened, on the awake clock.
var opened_ns: i96 = 0;

pub const StartReport = struct {};

pub fn setup(io: Io, base: std.mem.Allocator, roots: ?webbox.site.Roots) !StartReport {
    _ = base;
    _ = roots;
    try ideas.useOsHeap();
    state = onBigStack(ideas.newState, .{});
    opened_ns = Io.Clock.now(.awake, io).nanoseconds;
    return .{};
}

/// IdeaWeb reads a body only into its request record; none of its routes
/// uses one. A small cap, so a stray POST is read and not refused.
pub fn bodyLimit(path: []const u8) u64 {
    _ = path;
    return 4096;
}

pub fn routes(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator, _: *webbox.bus.Bus) !void {
    const target = try http.target(req, alloc);
    const path = http.pathOf(target);
    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html")) {
        if (req.head.method != .GET) return http.methodNotAllowed(req, .GET);
        return req.respond(@embedFile("idea_forge_page"), .{ .extra_headers = &.{http.html_ct} });
    }
    const who = try whoOf(req, alloc, target);
    const day = dayOf(io);
    const body = (try http.readLimitedBody(req, alloc, 4096)) orelse "";
    const answer = onBigStack(routeOne, .{ who, day, @tagName(req.head.method), target, body }) catch
        return req.respond("{\"error\":\"the request is not ASCII\"}\n", .{ .status = .bad_request, .extra_headers = &.{http.json_ct} });
    const status = statusOf(answer.status) orelse
        return req.respond("{\"error\":\"the house answered a status that is not one\"}\n", .{ .status = .bad_gateway, .extra_headers = &.{http.json_ct} });
    const content_type = try std.fmt.allocPrint(alloc, "{s}; charset=utf-8", .{answer.content_type});
    return req.respond(answer.body, .{ .status = @enumFromInt(status), .extra_headers = &.{
        .{ .name = "content-type", .value = content_type },
    } });
}

fn routeOne(who: []const u8, day: i64, method: []const u8, target: []const u8, body: []const u8) error{NotAscii}!ideas.Answer {
    const a = try ideas.route(state, who, day, method, target, body);
    state = a.state;
    return a;
}

/// IdeaServer's `resolve-who`: the proxy's word for the caller, else the
/// caller's own, else the shared name.
fn whoOf(req: *std.http.Server.Request, alloc: std.mem.Allocator, target: []const u8) ![]const u8 {
    if (try http.header(req, alloc, "x-forwarded-for")) |fwd| if (fwd.len > 0) return fwd;
    if (http.queryValue(target, "who")) |q| if (q.len > 0) return q;
    return "the-proxy";
}

/// IdeaServer's `current-day`: the house's day starts when it opens.
fn dayOf(io: Io) i64 {
    const since = Io.Clock.now(.awake, io).nanoseconds - opened_ns;
    return @intCast(@divFloor(since, std.time.ns_per_day));
}

/// HttpResponse's status is its text (`"429 Too Many Requests"`): the code
/// it begins with; null for one that does not.
pub fn statusOf(text: []const u8) ?u10 {
    const end = std.mem.indexOfScalar(u8, text, ' ') orelse text.len;
    const code = std.fmt.parseInt(u10, text[0..end], 10) catch return null;
    if (code < 100 or code > 599) return null;
    return code;
}

test "a status text's code, and none for what is not one" {
    try std.testing.expectEqual(@as(?u10, 429), statusOf("429 Too Many Requests"));
    try std.testing.expectEqual(@as(?u10, 200), statusOf("200 OK"));
    try std.testing.expectEqual(@as(?u10, 404), statusOf("404"));
    for ([_][]const u8{ "", "OK", "99 Low", "600 High", " 200 OK" }) |bad| try std.testing.expect(statusOf(bad) == null);
}

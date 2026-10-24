//! Cobblestone's game server, served by webbox (`webbox.site.Site(App)`):
//! apps/games/server.ps1's routes, with its game VM replaced by the same
//! Codex, GameServer.codex, compiled to Zig (src/gen/games.zig).
//!
//!   GET /, /index    apps/games/index.html, its games grid from games.json
//!   GET /games/ID    apps/games/classic/web/ID.html (else rungame.html),
//!                    `{{VERSION}}` filled in
//!   /api/*           the request line `METHOD PATH?QUERY` to GameServer's
//!                    `dispatch-request`; the line it prints, `STATUS TYPE
//!                    BODY`, is the answer (server.ps1's protocol)
//!   GET /web/*       apps/games/*, as is
//!   GET /assets/*    the checkout's assets/*, as is
//!
//! The pages and assets are read from the Cobblestone checkout
//! (`cobble_root`, from where the server runs), so an edit there shows on a
//! reload.

const std = @import("std");
const Io = @import("host_io").Io;
const webbox = @import("webbox");
const http = webbox.http;
const games = @import("games_api.zig").api;
const onBigStack = @import("stack.zig").onBigStack;

/// The Cobblestone checkout the pages come from; main.zig sets it from
/// COBBLESTONE_ROOT before the host starts.
pub var cobble_root: []const u8 = "../cobblestone-pin";

/// GameServer's store, threaded from request to request as server.ps1's
/// VM threads it. One handler runs at a time (webbox's hosts), so it is
/// shared plainly.
var store: games.Store = undefined;
/// The requests dispatched since the start, for the start's report and
/// /api/status's neighbour.
var dispatched: u64 = 0;

pub const StartReport = struct { cobble_root: []const u8 };

pub fn setup(io: Io, base: std.mem.Allocator, roots: ?webbox.site.Roots) !StartReport {
    _ = io;
    _ = base;
    _ = roots;
    try games.useOsHeap();
    store = onBigStack(games.newStore, .{});
    dispatched = 0;
    return .{ .cobble_root = cobble_root };
}

/// No route reads a body: GameServer's requests are their lines.
pub fn bodyLimit(path: []const u8) u64 {
    _ = path;
    return 0;
}

pub fn routes(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator, _: *webbox.bus.Bus) !void {
    const target = try http.target(req, alloc);
    const path = http.pathOf(target);
    if (std.mem.startsWith(u8, path, "/api/")) return api(req, alloc, target);
    if (req.head.method != .GET) return http.methodNotAllowed(req, .GET);
    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index")) return index(req, io, alloc);
    if (std.mem.startsWith(u8, path, "/games/")) return gamePage(req, io, alloc, path["/games/".len..]);
    if (std.mem.startsWith(u8, path, "/web/")) return staticFile(req, io, alloc, "apps/games", path["/web/".len..]);
    if (std.mem.startsWith(u8, path, "/assets/")) return staticFile(req, io, alloc, "assets", path["/assets/".len..]);
    return http.notFound(req);
}

/// **A REQUEST TO GAMESERVER**: its line as server.ps1 builds it, and the
/// line it prints parsed as server.ps1 parses it.
fn api(req: *std.http.Server.Request, alloc: std.mem.Allocator, target: []const u8) !void {
    const line = try std.fmt.allocPrint(alloc, "{s} {s}", .{ @tagName(req.head.method), target });
    const out = onBigStack(dispatchOne, .{line}) catch
        return jsonError(req, .bad_request, "{\"error\":\"the request line is not ASCII\"}");
    const printed = out orelse
        return jsonError(req, .bad_gateway, "{\"error\":\"malformed response from game server\"}");
    const parsed = parseAnswer(printed) orelse
        return jsonError(req, .bad_gateway, "{\"error\":\"malformed response from game server\"}");
    const content_type = try std.fmt.allocPrint(alloc, "{s}; charset=utf-8", .{parsed.content_type});
    return req.respond(parsed.body, .{ .status = @enumFromInt(parsed.status), .extra_headers = &.{
        .{ .name = "content-type", .value = content_type },
        .{ .name = "access-control-allow-origin", .value = "*" },
    } });
}

/// GameServer's answer to one line: the store moves on, and the first line
/// it printed (a copy: the store's heap is the chapter's).
fn dispatchOne(line: []const u8) error{NotAscii}!?[]const u8 {
    const r = try games.dispatch(store, line);
    store = r.store;
    dispatched += 1;
    return r.printed;
}

pub const Answer = struct { status: u10, content_type: []const u8, body: []const u8 };

/// `STATUS TYPE BODY`: a 3-digit status, a word, and the rest; null for
/// anything else (server.ps1's 502).
pub fn parseAnswer(line: []const u8) ?Answer {
    const sp1 = std.mem.indexOfScalar(u8, line, ' ') orelse return null;
    const sp2 = std.mem.indexOfScalarPos(u8, line, sp1 + 1, ' ') orelse return null;
    const status = std.fmt.parseInt(u10, line[0..sp1], 10) catch return null;
    if (status < 100 or status > 599 or sp2 == sp1 + 1) return null;
    return .{ .status = status, .content_type = line[sp1 + 1 .. sp2], .body = line[sp2 + 1 ..] };
}

fn jsonError(req: *std.http.Server.Request, status: std.http.Status, body: []const u8) !void {
    return req.respond(body, .{ .status = status, .extra_headers = &.{http.json_ct} });
}

/// The checkout's `dir/rel`, `rel` a path of plain names (letters, digits,
/// `.`, `-`, `_`, none of them `.` or `..`); null for any other.
fn underCheckout(alloc: std.mem.Allocator, dir: []const u8, rel: []const u8) !?[]const u8 {
    if (rel.len == 0) return null;
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return null;
        for (part) |c| if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == '_')) return null;
    }
    return try std.fs.path.join(alloc, &.{ cobble_root, dir, rel });
}

fn staticFile(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator, dir: []const u8, rel: []const u8) !void {
    const path = (try underCheckout(alloc, dir, rel)) orelse return http.notFound(req);
    const body = (try webbox.store.readOrNull(io, alloc, path, .limited(16 * 1024 * 1024))) orelse return http.notFound(req);
    return req.respond(body, .{ .extra_headers = &.{
        .{ .name = "content-type", .value = mimeOf(rel) },
        .{ .name = "cache-control", .value = "no-cache" },
    } });
}

/// server.ps1's table of types.
fn mimeOf(name: []const u8) []const u8 {
    const ext = std.fs.path.extension(name);
    const table = [_][2][]const u8{
        .{ ".png", "image/png" },        .{ ".jpg", "image/jpeg" },           .{ ".jpeg", "image/jpeg" },
        .{ ".webp", "image/webp" },      .{ ".gif", "image/gif" },            .{ ".svg", "image/svg+xml" },
        .{ ".wav", "audio/wav" },        .{ ".mp3", "audio/mpeg" },           .{ ".ogg", "audio/ogg" },
        .{ ".css", "text/css" },         .{ ".js", "application/javascript" }, .{ ".json", "application/json" },
        .{ ".html", "text/html" },
    };
    for (table) |row| if (std.ascii.eqlIgnoreCase(ext, row[0])) return row[1];
    return "application/octet-stream";
}

/// What `{{VERSION}}` becomes: server.ps1 puts style.css's modified time,
/// to bust a cache; a constant does as well while the pages are read fresh.
const version = "1";

fn gamePage(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator, raw_id: []const u8) !void {
    // server.ps1 keeps [a-z0-9] of the id and drops the rest.
    var id: std.ArrayList(u8) = .empty;
    for (raw_id) |c| if (std.ascii.isLower(c) or std.ascii.isDigit(c)) try id.append(alloc, c);
    const own = try std.fmt.allocPrint(alloc, "{s}.html", .{id.items});
    const page = (if (id.items.len > 0) try readUnder(io, alloc, "apps/games/classic/web", own) else null) orelse
        (try readUnder(io, alloc, "apps/games/classic/web", "rungame.html")) orelse return http.notFound(req);
    const body = try std.mem.replaceOwned(u8, alloc, page, "{{VERSION}}", version);
    return req.respond(body, .{ .extra_headers = &.{http.html_ct} });
}

fn readUnder(io: Io, alloc: std.mem.Allocator, dir: []const u8, rel: []const u8) !?[]u8 {
    const path = (try underCheckout(alloc, dir, rel)) orelse return null;
    return webbox.store.readOrNull(io, alloc, path, .limited(4 * 1024 * 1024));
}

const Game = struct { id: []const u8, name: []const u8, cat: []const u8, desc: []const u8, players: []const u8, icon: []const u8 };

/// **THE CATALOG PAGE**: index.html with its games grid, built from
/// games.json as server.ps1's Build-GamesContent builds it, and in place
/// of its status card (the seed, the tests, Perforce's changes: the
/// Windows box's facts) one saying what serves.
fn index(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator) !void {
    const template = (try readUnder(io, alloc, "apps/games", "index.html")) orelse return http.notFound(req);
    const json = (try readUnder(io, alloc, "apps/games", "games.json")) orelse "[]";
    const catalog = try std.json.parseFromSliceLeaky([]Game, alloc, json, .{ .ignore_unknown_fields = true });
    const status = try std.fmt.allocPrint(alloc,
        \\<div class="subtitle">Served by webbox (Zig) &middot; GameServer.codex compiled to Zig by codexzig &middot; {d} game requests answered</div>
    , .{dispatched});
    var page = try std.mem.replaceOwned(u8, alloc, template, "{{VERSION}}", version);
    page = try std.mem.replaceOwned(u8, alloc, page, "{{STATUS}}", status);
    page = try std.mem.replaceOwned(u8, alloc, page, "{{GAMES}}", try gamesContent(alloc, catalog));
    return req.respond(page, .{ .extra_headers = &.{http.html_ct} });
}

fn catColor(cat: []const u8) []const u8 {
    const table = [_][2][]const u8{
        .{ "Board", "#3fb950" }, .{ "Card", "#f85149" },  .{ "Strategy", "#d29922" }, .{ "Puzzle", "#58a6ff" },
        .{ "Dice", "#bc8cff" },  .{ "Other", "#8b949e" }, .{ "Magic", "#d2a8ff" },    .{ "Utility", "#484f58" },
    };
    for (table) |row| if (std.mem.eql(u8, cat, row[0])) return row[1];
    return "#8b949e";
}

fn gamesContent(alloc: std.mem.Allocator, catalog: []const Game) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(alloc);
    const out = &w.writer;
    try out.writeAll("<div class=\"games-toolbar\">\n  <div class=\"filter-bar\">\n");
    for ([_][]const u8{ "All", "Board", "Card", "Strategy", "Puzzle", "Dice", "Other", "Magic", "Utility" }) |cat| {
        const lower = try std.ascii.allocLowerString(alloc, cat);
        try out.print("    <button class='filter-pill{s}' data-cat='{s}' onclick='filterGames(\"{s}\")'>{s}</button>\n", .{ if (std.mem.eql(u8, cat, "All")) " active" else "", lower, lower, cat });
    }
    try out.print(
        \\  </div>
        \\  <div class="search-bar">
        \\    <input type="text" id="game-search" placeholder="Search games..." oninput="filterGames(document.querySelector('.filter-pill.active').dataset.cat)">
        \\    <span id="game-count" class="game-count">Showing {d} of {d} games</span>
        \\    <button class="sound-toggle" id="sound-toggle" onclick="toggleSound()">&#x1F507; Sound Off</button>
        \\  </div>
        \\</div>
        \\<div class="game-grid">
        \\
    , .{ catalog.len, catalog.len });
    for (catalog) |g| {
        const color = catColor(g.cat);
        const players = if (std.mem.eql(u8, g.players, "-"))
            try alloc.dupe(u8, "<span class='game-players'>framework</span>")
        else
            try std.fmt.allocPrint(alloc, "<span class='game-players'>{s} player{s}</span>", .{ g.players, if (std.mem.eql(u8, g.players, "1")) "" else "s" });
        try out.print(
            \\  <div class="game-card" data-category="{s}" data-name="{s}" data-id="{s}" onclick="location.href='/games/{s}'" onmouseenter="previewPlay('{s}')" onmouseleave="previewStop()">
            \\    <div class="game-thumb">
            \\      <img src="/assets/games/thumbs/{s}.png" alt="{s}"
            \\           onerror="this.style.display='none';this.nextElementSibling.style.display='flex'">
            \\      <div class="game-icon-fallback">{s}</div>
            \\    </div>
            \\    <div class="game-info">
            \\      <div class="game-title-row">
            \\        <h3 class="game-name">{s}</h3>
            \\        <span class="game-badge" style="background:{s}22;color:{s};border-color:{s}44">{s}</span>
            \\      </div>
            \\      <p class="game-desc">{s}</p>
            \\      {s}
            \\    </div>
            \\  </div>
            \\
        , .{ try std.ascii.allocLowerString(alloc, g.cat), try std.ascii.allocLowerString(alloc, g.name), g.id, g.id, g.id, g.id, g.name, g.icon, g.name, color, color, color, g.cat, g.desc, players });
    }
    try out.writeAll("</div>\n");
    return w.written();
}

test "an answer line is STATUS TYPE BODY, the body all the rest; anything else is none" {
    const a = parseAnswer("200 application/json {\"a\": 1}").?;
    try std.testing.expectEqual(@as(u10, 200), a.status);
    try std.testing.expectEqualStrings("application/json", a.content_type);
    try std.testing.expectEqualStrings("{\"a\": 1}", a.body);
    try std.testing.expectEqualStrings("Not Found", parseAnswer("404 text/plain Not Found").?.body);
    for ([_][]const u8{ "", "200", "200 application/json", "20x text/plain hi", "999 text/plain hi", "200  body" }) |bad|
        try std.testing.expect(parseAnswer(bad) == null);
}

test "a path under the checkout is plain names only" {
    const a = std.testing.allocator;
    const ok = (try underCheckout(a, "apps/games", "classic/web/go.html")).?;
    defer a.free(ok);
    try std.testing.expect(std.mem.endsWith(u8, ok, "apps/games/classic/web/go.html"));
    for ([_][]const u8{ "", "../x", "a/../b", "a//b", "./a", "a/b c", "a\\b" }) |bad|
        try std.testing.expect(try underCheckout(a, "apps/games", bad) == null);
}

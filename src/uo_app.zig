//! uoaix on webbox, a first proof: GameVendorReplay.codex, compiled to Zig
//! (src/gen/uo.zig), run by a request and answered as text.
//!
//!   GET /uo/vendor-proof    the proof's lines, as its `.expected` has them
//!
//! Each run starts the Codex heap from its base, so a run costs nothing
//! that lasts; the host's request turns keep runs one at a time.

const std = @import("std");
const Io = @import("host_io").Io;
const webbox = @import("webbox");
const http = webbox.http;
const uo = @import("gen/uo.zig").api;

pub const prefix = "/uo";

/// The Codex heap's region: the proof uses about 75 MB.
const heap_region: usize = 256 * 1024 * 1024;

pub const StartReport = struct {};

pub fn setup(io: Io, base: std.mem.Allocator, roots: ?webbox.site.Roots) !StartReport {
    _ = io;
    _ = roots;
    const region = try base.alignedAlloc(u8, .fromByteUnits(4096), heap_region);
    @memset(region, 0);
    uo.heapGive(region);
    return .{};
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

pub fn routes(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator, _: *webbox.bus.Bus) !void {
    _ = io;
    const path = http.pathUnder(http.pathOf(try http.target(req, alloc)), prefix) orelse return http.notFound(req);
    if (!std.mem.eql(u8, path, "/vendor-proof")) return http.notFound(req);
    if (req.head.method != .GET) return http.methodNotAllowed(req, .GET);
    printed = .empty;
    printed_alloc = alloc;
    uo.runProof(sink);
    return req.respond(printed.items, .{ .extra_headers = &.{http.plain_ct} });
}

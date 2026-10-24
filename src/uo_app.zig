//! uoaix on webbox, first proofs: two of apps/uoaix/proofs/, compiled to Zig,
//! each run by a request and answered as text, its lines as its `.expected`
//! has them.
//!
//!   GET /uo/vendor-proof    GameVendorReplay (src/gen/uo.zig)
//!   GET /uo/town-proof      TownLiveProof (src/gen/uo_town.zig)
//!
//! Each run starts the Codex heap from its base, so a run costs nothing
//! that lasts; the host's request turns keep runs one at a time.

const std = @import("std");
const Io = @import("host_io").Io;
const webbox = @import("webbox");
const http = webbox.http;
const vendor = @import("gen/uo.zig").api;
const town = @import("gen/uo_town.zig").api;

pub const prefix = "/uo";

/// Each proof's Codex heap region: the vendor proof uses about 75 MB, the
/// town proof about 24 MB.
const heap_region: usize = 128 * 1024 * 1024;

pub const StartReport = struct {};

pub fn setup(io: Io, base: std.mem.Allocator, roots: ?webbox.site.Roots) !StartReport {
    _ = io;
    _ = roots;
    inline for (.{ vendor, town }) |lib| {
        const region = try base.alignedAlloc(u8, .fromByteUnits(4096), heap_region);
        @memset(region, 0);
        lib.heapGive(region);
    }
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
    const run = if (std.mem.eql(u8, path, "/vendor-proof"))
        &vendor.runProof
    else if (std.mem.eql(u8, path, "/town-proof"))
        &town.runProof
    else
        return http.notFound(req);
    if (req.head.method != .GET) return http.methodNotAllowed(req, .GET);
    printed = .empty;
    printed_alloc = alloc;
    run(sink);
    return req.respond(printed.items, .{ .extra_headers = &.{http.plain_ct} });
}

//! GameServer.codex's face for a host (src/gen/games.zig, its library): the
//! store it threads from request to request, a fresh one, and its dispatch,
//! which answers by printing one line, `STATUS TYPE BODY` (apps/games/
//! server.ps1's protocol, unchanged).

const lib = @import("gen/games.zig");

pub const api = struct {
    pub const Store = lib.GameStore;

    /// The Codex heap's region, from the OS: the store only grows.
    pub fn useOsHeap() !void {
        try @import("os_heap.zig").give(lib, 1 << 30);
    }

    pub fn newStore() Store {
        return lib.game_store_new();
    }

    /// One request line (`GET /api/tictactoe/step`, as server.ps1 builds
    /// it), ASCII: the next store, and the first line the chapter printed
    /// (null if it printed none), UTF-8, valid until the next call.
    pub fn dispatch(store: Store, line: []const u8) error{NotAscii}!struct { store: Store, printed: ?[]const u8 } {
        const cce = try lib.cx.fromAscii(line);
        printed_first = null;
        lib.cx_host_print = capture;
        defer lib.cx_host_print = null;
        const next = lib.dispatch_request(store, cce);
        return .{ .store = next, .printed = printed_first };
    }

    /// The bump frontier, for a host that brackets work it can throw away.
    /// The store lives on the same heap, so a host that keeps it may not
    /// rewind past its making.
    pub fn heapMark() i64 {
        return lib.cx.heapMark();
    }
};

var printed_first: ?[]const u8 = null;

fn capture(line: []const u8) void {
    if (printed_first == null) printed_first = line;
}

//! IdeaWeb.codex's face for a host (src/gen/ideas.zig, its library): the
//! state the house threads from customer to customer, a fresh one, and
//! `idea-route-at`, which takes the caller and the service day from its host
//! (IdeaServer's `resolve-who` and `current-day`, which webbox answers).

const lib = @import("gen/ideas.zig");

pub const api = struct {
    pub const State = lib.IdeaState;

    /// The Codex heap's region, from the OS: the state only grows.
    pub fn useOsHeap() !void {
        try @import("os_heap.zig").give(lib, 256 << 20);
    }

    pub fn newState() State {
        return lib.idea_state_new();
    }

    /// The next state and the response, its texts UTF-8.
    pub const Answer = struct { state: State, status: []const u8, content_type: []const u8, body: []const u8 };

    /// One request: its method, its target (path and query, as the line
    /// carries it) and its body, all ASCII, from caller `who` on service day
    /// `day`.
    pub fn route(state: State, who: []const u8, day: i64, method: []const u8, target: []const u8, body: []const u8) error{NotAscii}!Answer {
        const req = lib.cx.new(lib.HttpRequestS{
            .method = try lib.cx.fromAscii(method),
            .path_ = try lib.cx.fromAscii(target),
            .body = try lib.cx.fromAscii(body),
            .valid = true,
        });
        const pair = lib.idea_route_at(state, try lib.cx.fromAscii(who), day, req);
        switch (pair.*) {
            .MkTup2 => |t| return .{
                .state = t[0],
                .status = lib.cx.utf8(t[1].status),
                .content_type = lib.cx.utf8(t[1].content_type),
                .body = lib.cx.utf8(t[1].body),
            },
        }
    }
};

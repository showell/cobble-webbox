//! ChatServer.codex's and ChatStore.codex's face for a host (src/gen/chat.zig,
//! their library): the state, a fresh one, the state as the disk holds it, a
//! mark before a route and what the route changed written against it, and
//! `chat-route`, which takes the time of day and a fresh token from its host
//! as ChatServer's prose says. The heap's region is the host's on every host
//! (src/chat_host.zig gives it).

const lib = @import("gen/chat.zig");

pub const api = struct {
    pub const State = lib.ChatState;
    pub const Mark = lib.ChatStoreMark;
    pub const FileHost = lib.CxFileHost;

    /// The files ChatStore keeps through the FileSystem effect: the host's.
    pub fn useFiles(host: ?FileHost) void {
        lib.cx_file_host = host;
    }

    pub const heapGive = lib.cx.heapGive;
    pub const heapUsed = lib.cx.heapUsed;
    pub const heapMark = lib.cx.heapMark;
    pub const heapBack = lib.cx.heapBack;
    pub const heapReset = lib.cx.heapReset;

    pub fn newState() State {
        return lib.chat_state_new();
    }

    /// The state in the host's files (under `codex-chat/`), and why they
    /// cannot be trusted with the next write: empty when they can.
    pub const Loaded = struct { state: State, problem: []const u8 };

    pub fn load() Loaded {
        const l = lib.chat_store_load();
        return .{ .state = l.sl_state, .problem = lib.cx.utf8(l.sl_problem) };
    }

    /// Taken before a route: what `save` writes is what the route added past
    /// it. (The state before a route is no record of it: list-push writes in
    /// place while a list has room.)
    pub fn mark(state: State) Mark {
        return lib.chat_store_mark(state);
    }

    /// What changed since `m`, written; whether every write went through.
    /// After a False the state in hand holds what the disk does not: `load`
    /// again.
    pub fn save(m: Mark, state: State) bool {
        return lib.chat_store_save(m, state);
    }

    pub const Answer = struct { state: State, status: []const u8, content_type: []const u8, body: []const u8 };

    /// One request (method, target, body: ASCII), at `time` (`HH:mm`), with
    /// a fresh token for the account it may make.
    pub fn route(state: State, time: []const u8, token: []const u8, method: []const u8, target: []const u8, body: []const u8) error{NotAscii}!Answer {
        const host = lib.cx.new(lib.ChatHostS{
            .ch_time = try lib.cx.fromAscii(time),
            .ch_token = try lib.cx.fromAscii(token),
        });
        const req = lib.cx.new(lib.HttpRequestS{
            .method = try lib.cx.fromAscii(method),
            .path_ = try lib.cx.fromAscii(target),
            .body = try lib.cx.fromAscii(body),
            .valid = true,
        });
        const pair = lib.chat_route(state, host, req);
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

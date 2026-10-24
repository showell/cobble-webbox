//! ChatServer.codex and ChatStore.codex, compiled to Zig (src/gen/chat.zig),
//! keeping a chat on a disk: a blank FAT16 volume in memory, a short
//! conversation saved to it through the Fat16 foreword request by request
//! as the site saves it, and the state read back from the same bytes as a
//! restarted server reads it; then a damaged account file, which a load
//! must refuse rather than serve.

const std = @import("std");
const chat = @import("gen/chat.zig").api;
const fat16_blank = @import("fat16_blank.zig");

var image: []u8 = &.{};

fn readSector(lba: u64, sector: *[512]u8) bool {
    if ((lba + 1) * 512 > image.len) return false;
    @memcpy(sector, image[lba * 512 ..][0..512]);
    return true;
}

fn writeSector(lba: u64, sector: *const [512]u8) bool {
    if ((lba + 1) * 512 > image.len) return false;
    @memcpy(image[lba * 512 ..][0..512], sector);
    return true;
}

/// `f(args)` on the chapter's stack, as the site calls it.
fn big(comptime f: anytype, args: anytype) @typeInfo(@TypeOf(f)).@"fn".return_type.? {
    return @import("stack.zig").onBigStack(f, args);
}

/// One request, saved as the site saves it: a mark before the route, what
/// the route added written after it.
fn get(state: *chat.State, target: []const u8, token: []const u8) ![]const u8 {
    const Call = struct {
        fn run(s: *chat.State, t: []const u8, tok: []const u8) error{ NotAscii, NotSaved }![]const u8 {
            const m = chat.mark(s.*);
            const a = try chat.route(s.*, "12:00", tok, "GET", t, "");
            s.* = a.state;
            if (!chat.save(m, s.*)) return error.NotSaved;
            return a.body;
        }
    };
    return big(Call.run, .{ state, target, token });
}

fn loadClean() !chat.State {
    const l = big(chat.load, .{});
    try std.testing.expectEqualStrings("", l.problem);
    return l.state;
}

test "a chat saved to a FAT16 disk through Codex is there after a restart" {
    image = try std.testing.allocator.alloc(u8, fat16_blank.image_bytes);
    defer std.testing.allocator.free(image);
    @memset(image, 0);
    fat16_blank.head(image[0 .. fat16_blank.head_sectors * 512]);
    chat.useDisk(.{ .read = readSector, .write = writeSector });
    defer chat.useDisk(null);

    // A blank disk loads as a fresh state: nobody holds a token yet.
    var state = try loadClean();
    try std.testing.expectEqualStrings("{\"error\":\"auth\"}", try get(&state, "/api/chat/me?t=tok-ann", "x"));

    _ = try get(&state, "/api/chat/register?name=ann", "tok-ann");
    _ = try get(&state, "/api/chat/register?name=ben", "tok-ben");
    try std.testing.expectEqualStrings("{\"convId\":\"c1\"}", try get(&state, "/api/chat/start?t=tok-ann&with=ben", "x"));
    _ = try get(&state, "/api/chat/send?t=tok-ann&to=c1&body=kept+on+disk", "x");
    _ = try get(&state, "/api/chat/send?t=tok-ben&to=c1&body=and+appended", "x");

    // Each message is a line of its conversation's messages file.
    try std.testing.expect(std.mem.indexOf(u8, image, "{\"id\":1,\"sender\":\"ann\",\"body\":\"kept on disk\",\"time\":\"12:00\"}\n{\"id\":2,\"sender\":\"ben\",\"body\":\"and appended\",\"time\":\"12:00\"}\n") != null);

    // A restart: nothing kept but the disk.
    var again = try loadClean();
    const msgs = try get(&again, "/api/chat/messages?t=tok-ben&conv=c1", "x");
    try std.testing.expectEqualStrings("{\"count\":\"2\",\"body-0\":\"kept on disk\",\"sender-0\":\"ann\",\"time-0\":\"12:00\",\"mine-0\":\"0\",\"body-1\":\"and appended\",\"sender-1\":\"ben\",\"time-1\":\"12:00\",\"mine-1\":\"1\"}", msgs);
    // And it goes on from where it was: the next conversation is c2.
    _ = try get(&again, "/api/chat/register?name=cat", "tok-cat");
    try std.testing.expectEqualStrings("{\"convId\":\"c2\"}", try get(&again, "/api/chat/start?t=tok-ben&with=cat", "x"));
    // A name claimed before the restart is still claimed after it.
    try std.testing.expectEqualStrings("{\"error\":\"name taken\"}", try get(&again, "/api/chat/register?name=ann", "tok-other"));

    // An account file that does not parse is a disk the next claim could
    // overwrite someone on: the load says so instead of serving it.
    const ann = std.mem.indexOf(u8, image, "{\"name\":\"ann\"").?;
    image[ann] = 'x';
    const damaged = big(chat.load, .{});
    try std.testing.expectEqualStrings("codex-chat/users/0.json is missing or does not parse", damaged.problem);
}

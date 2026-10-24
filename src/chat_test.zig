//! ChatServer.codex and ChatStore.codex, compiled to Zig (src/gen/chat.zig),
//! keeping a chat on a disk: a blank FAT16 volume in memory, a short
//! conversation saved to it through the Fat16 foreword, and the state read
//! back from the same bytes as a restarted server reads it.

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

fn get(state: *chat.State, target: []const u8, token: []const u8) ![]const u8 {
    const Call = struct {
        fn run(s: *chat.State, t: []const u8, tok: []const u8) error{NotAscii}![]const u8 {
            const a = try chat.route(s.*, "12:00", tok, "tok-second", "GET", t, "");
            s.* = a.state;
            return a.body;
        }
    };
    return big(Call.run, .{ state, target, token });
}

test "a chat saved to a FAT16 disk through Codex is there after a restart" {
    image = try std.testing.allocator.alloc(u8, fat16_blank.image_bytes);
    defer std.testing.allocator.free(image);
    @memset(image, 0);
    fat16_blank.head(image[0 .. fat16_blank.head_sectors * 512]);
    chat.useDisk(.{ .read = readSector, .write = writeSector });
    defer chat.useDisk(null);

    // A blank disk loads as a fresh state: nobody holds a token yet.
    var state = big(chat.load, .{});
    try std.testing.expectEqualStrings("{\"error\":\"auth\"}", try get(&state, "/api/chat/me?t=tok-ann", "x"));

    _ = try get(&state, "/api/chat/register?name=ann", "tok-ann");
    _ = try get(&state, "/api/chat/register?name=ben", "tok-ben");
    try std.testing.expectEqualStrings("{\"convId\":\"c1\"}", try get(&state, "/api/chat/start?t=tok-ann&with=ben", "x"));
    _ = try get(&state, "/api/chat/send?t=tok-ann&to=c1&body=kept+on+disk", "x");
    try std.testing.expect(big(chat.save, .{state}));

    // The root directory holds the file, by its 8.3 name.
    try std.testing.expect(std.mem.indexOf(u8, image[67 * 512 .. 99 * 512], "CHAT    JSN") != null);

    // A restart: nothing kept but the disk.
    var again = big(chat.load, .{});
    const msgs = try get(&again, "/api/chat/messages?t=tok-ben&conv=c1", "x");
    try std.testing.expectEqualStrings("{\"count\":\"1\",\"body-0\":\"kept on disk\",\"sender-0\":\"ann\",\"time-0\":\"12:00\",\"mine-0\":\"0\"}", msgs);
    // And it goes on from where it was: the next conversation is c2.
    try std.testing.expectEqualStrings("{\"convId\":\"c2\"}", try get(&again, "/api/chat/start?t=tok-ben&with=cat", "x"));
}

const std = @import("std");

pub const Kcp = @import("kcp_core.zig").Kcp;
pub const KcpHeader = @import("kcp_header.zig").KcpHeader;
pub const Segment = @import("segment.zig").Segment;
pub const KcpError = @import("kcp_core.zig").KcpError;

test "KcpHeader encode/decode" {
    const header = KcpHeader{
        .conv = 0x12345678,
        .cmd = 81,
        .frg = 10,
        .wnd = 128,
        .ts = 0xABCDEF01,
        .sn = 0x11223344,
        .una = 0x55667788,
        .len = 100,
    };

    var buf: [KcpHeader.SIZE]u8 = undefined;
    header.encode(&buf);

    const decoded = KcpHeader.decode(&buf);
    try std.testing.expectEqual(header.conv, decoded.conv);
    try std.testing.expectEqual(header.cmd, decoded.cmd);
    try std.testing.expectEqual(header.frg, decoded.frg);
    try std.testing.expectEqual(header.wnd, decoded.wnd);
    try std.testing.expectEqual(header.ts, decoded.ts);
    try std.testing.expectEqual(header.sn, decoded.sn);
    try std.testing.expectEqual(header.una, decoded.una);
    try std.testing.expectEqual(header.len, decoded.len);
}

test "Segment init/deinit" {
    const allocator = std.testing.allocator;
    var seg = Segment{};
    defer seg.deinit(allocator);

    try seg.data.appendSlice(allocator, "hello world");
    try std.testing.expectEqualStrings("hello world", seg.data.items);
}

test "Kcp basic send/recv" {
    const allocator = std.testing.allocator;
    var kcp = try Kcp.init(0x1234, null, dummy_output, allocator);
    defer kcp.deinit();

    try kcp.send("hello");
    try kcp.update(0);
    // Since we don't have a real network, we manually move data for testing
    // In a real test we'd need two KCP instances.
}

test "Kcp fragmentation" {
    const allocator = std.testing.allocator;
    var kcp = try Kcp.init(0x1234, null, dummy_output, allocator);
    defer kcp.deinit();

    // Large data to trigger fragmentation (MSS is 1376 by default)
    const large_data = "A" ** 2000;
    try kcp.send(large_data);
    
    // Check if it's fragmented in snd_queue
    // snd_queue is now a DoublyLinkedList, so we check .len
    try std.testing.expect(kcp.snd_queue.len > 1);
}

test "Kcp loopback data exchange" {
    const allocator = std.testing.allocator;
    
    var ctx = LoopbackContext{
        .allocator = allocator,
        .packets = .{},
    };
    defer {
        for (ctx.packets.items) |p| allocator.free(p);
        ctx.packets.deinit(allocator);
    }

    var kcp_send = try Kcp.init(0x1234, &ctx, loopback_output, allocator);
    defer kcp_send.deinit();

    var kcp_recv = try Kcp.init(0x1234, &ctx, loopback_output, allocator);
    defer kcp_recv.deinit();

    const msg = "kcp loopback test message";
    try kcp_send.send(msg);
    try kcp_send.update(100);

    // After send.update, loopback_output should have been called
    try std.testing.expect(ctx.packets.items.len > 0);

    for (ctx.packets.items) |p| {
        try kcp_recv.input(p, 100);
    }
    
    var buffer: [1024]u8 = undefined;
    const n = try kcp_recv.recv(&buffer);
    try std.testing.expectEqualStrings(msg, buffer[0..n]);
}

const LoopbackContext = struct {
    allocator: std.mem.Allocator,
    packets: std.ArrayList([]u8),
};

fn loopback_output(buf: []const u8, user: ?*const anyopaque) void {
    const ctx: *LoopbackContext = @ptrCast(@constCast(@alignCast(user.?)));
    const copy = ctx.allocator.alloc(u8, buf.len) catch unreachable;
    @memcpy(copy, buf);
    ctx.packets.append(ctx.allocator, copy) catch unreachable;
}

fn dummy_output(buf: []const u8, user: ?*const anyopaque) void {
    _ = buf;
    _ = user;
}

const std = @import("std");
const kcp = @import("kcp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const socket = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM | std.posix.SOCK.NONBLOCK, 0);
    defer std.posix.close(socket);

    var kcp_cb = try kcp.Kcp.init(0x11223344, @ptrCast(&socket), udp_client_output, allocator);
    defer kcp_cb.deinit();

    kcp_cb.setNoDelay(true, 10, 2, true);

    std.debug.print("Client started, sending request...\n", .{});
    try kcp_cb.send("Hello from Client!");

    var buf: [2048]u8 = undefined;
    while (true) {
        const now = @as(u32, @truncate(@as(u64, @bitCast(std.time.milliTimestamp()))));
        try kcp_cb.update(now);

        const rc = std.posix.recvfrom(socket, &buf, 0, null, null) catch |err| switch (err) {
            error.WouldBlock, error.ConnectionResetByPeer => 0,
            else => return err,
        };
        if (rc > 0) {
            try kcp_cb.input(buf[0..rc], now);
            
            var recv_buf: [1024]u8 = undefined;
            const n = kcp_cb.recv(&recv_buf) catch |err| switch (err) {
                error.NoMoreData => 0,
                else => return err,
            };
            if (n > 0) {
                std.debug.print("Received response from server: {s}\n", .{recv_buf[0..n]});
                break;
            }
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
}

fn udp_client_output(buf: []const u8, user: ?*const anyopaque) void {
    const sock = @as(*const std.posix.socket_t, @ptrCast(@alignCast(user.?)));
    const dest_addr = std.net.Address.parseIp4("127.0.0.1", 9999) catch return;
    _ = std.posix.sendto(sock.*, buf, 0, &dest_addr.any, dest_addr.getOsSockLen()) catch return;
}

const std = @import("std");
const kcp = @import("kcp");

const KcpInstance = struct {
    kcp_cb: kcp.Kcp,
    addr: std.net.Address,
    socket: std.posix.socket_t,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const addr = try std.net.Address.parseIp4("127.0.0.1", 9999);
    const socket = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM | std.posix.SOCK.NONBLOCK, 0);
    defer std.posix.close(socket);

    try std.posix.bind(socket, &addr.any, addr.getOsSockLen());

    // Use a u64 key (IP << 16 | port) for simple IPv4 client tracking
    var clients = std.AutoHashMap(u64, *KcpInstance).init(allocator);
    defer {
        var it = clients.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.kcp_cb.deinit();
            allocator.destroy(entry.value_ptr.*);
        }
        clients.deinit();
    }

    std.debug.print("Server started on 127.0.0.1:9999\n", .{});

    var buf: [2048]u8 = undefined;

    while (true) {
        const now = @as(u32, @truncate(@as(u64, @bitCast(std.time.milliTimestamp()))));
        var client_raw_addr: std.posix.sockaddr = undefined;
        var client_addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);

        const rc = std.posix.recvfrom(socket, &buf, 0, &client_raw_addr, &client_addr_len) catch |err| switch (err) {
            error.WouldBlock, error.ConnectionResetByPeer => 0,
            else => return err,
        };

        if (rc > 0) {
            const client_addr = std.net.Address{ .any = client_raw_addr };
            // Simple key for IPv4: combine address and port
            const key = (@as(u64, client_addr.in.sa.addr) << 16) | client_addr.in.sa.port;

            const entry = try clients.getOrPut(key);
            if (!entry.found_existing) {
                const instance = try allocator.create(KcpInstance);
                instance.* = .{
                    .kcp_cb = try kcp.Kcp.init(0x11223344, instance, udp_output, allocator),
                    .addr = client_addr,
                    .socket = socket,
                };
                instance.kcp_cb.setNoDelay(true, 10, 2, true);
                entry.value_ptr.* = instance;
                std.debug.print("New client linked! {any}\n", .{client_addr.in.sa});
            }

            const instance = entry.value_ptr.*;
            try instance.kcp_cb.input(buf[0..rc], now);

            var recv_buf: [1024]u8 = undefined;
            while (true) {
                const n = instance.kcp_cb.recv(&recv_buf) catch |err| switch (err) {
                    error.NoMoreData => break,
                    else => return err,
                };
                if (n > 0) {
                    std.debug.print("Received: {s}\n", .{recv_buf[0..n]});
                    var out_reply: [128]u8 = undefined;
                    const full_reply = try std.fmt.bufPrint(&out_reply, "Server Echo: {s}", .{recv_buf[0..n]});
                    try instance.kcp_cb.send(full_reply);
                }
            }
        }

        var it = clients.iterator();

        while (it.next()) |entry| {
            try entry.value_ptr.*.kcp_cb.update(now);
        }

        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
}

fn udp_output(buf: []const u8, user: ?*const anyopaque) void {
    const instance = @as(*KcpInstance, @ptrCast(@alignCast(@constCast(user.?))));
    _ = std.posix.sendto(instance.socket, buf, 0, &instance.addr.any, instance.addr.getOsSockLen()) catch return;
}

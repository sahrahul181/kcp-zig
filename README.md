# Zig KCP

A high-performance, production-ready port of the [KCP protocol](https://github.com/skywind3000/kcp) to Zig 0.15.2.

KCP is a fast and reliable ARQ protocol that can reduce average latency by 30%-40% and maximum latency by 3x compared to TCP, at the cost of 10%-20% more bandwidth.

## Features

- **Optimized for Zig 0.15.2**: Built using modern Zig idioms and safety features.
- **Zero-Allocation Hot Path**: Uses a `SegmentPool` to recycle memory. Once the initial pool is warmed up, data transmission and reception perform zero heap allocations.
- **Intrusive Data Structures**: Uses intrusive linked lists for segment management, reducing pointer indirection and improving cache performance.
- **Thread-Safe**: Integrated `std.Thread.Mutex` ensures safe access across multiple threads (e.g., networking thread and game logic thread).
- **C-Compatible**: Fully compatible with the original C implementation at the wire level.
- **Modern API**: Simplified API using Zig error unions and slices.

## Installation

This repository can be used as a Zig module.

1. Add this repository to your `build.zig.zon` (or just copy the `src` folder).
2. In your `build.zig`:

```zig
const kcp_mod = b.addModule("kcp", .{
    .root_source_file = b.path("src/root.zig"),
});
exe.root_module.addImport("kcp", kcp_mod);
```

## Usage Example

### Simple Client

```zig
const std = @import("std");
const kcp = @import("kcp");

// UDP output callback
fn udp_output(buf: []const u8, user: ?*const anyopaque) void {
    const socket = @as(*std.posix.socket_t, @ptrCast(@constCast(user.?)));
    _ = std.posix.send(socket.*, buf, 0) catch return;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const socket = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
    
    var my_kcp = try kcp.Kcp.init(0x11223344, &socket, udp_output, allocator);
    defer my_kcp.deinit();

    // Set fastest mode
    my_kcp.setNoDelay(true, 10, 2, true);

    try my_kcp.send("Hello KCP!");
    
    // In your main loop
    while (true) {
        const now = @as(u32, @truncate(@as(u64, @bitCast(std.time.milliTimestamp()))));
        try my_kcp.update(now);
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
}
```

## Configuration (NoDelay Mode)

Use `setNoDelay` to configure the protocol performance:

```zig
// nodelay: true, interval: 10ms, resend: 2, nc: true (no congestion control)
kcp.setNoDelay(true, 10, 2, true);
```

| Parameter | Default | Recommended for Games |
| :--- | :--- | :--- |
| `nodelay` | `false` | `true` |
| `interval` | `100ms` | `10ms` - `20ms` |
| `resend` | `0` (off) | `2` |
| `nc` | `false` | `true` |

## Building & Testing

Run library tests:
```bash
zig build test
```

Run included examples:
```bash
zig build run-server
zig build run-client
```

## Cross-Implementation Testing

This project includes a C client and server for compatibility verification.

Compile C examples (requires `zig` to be in PATH):
```bash
zig cc -o c_client.exe example/c_client.c c_kcp/i_kcp.c -lws2_32
zig cc -o c_server.exe example/c_server.c c_kcp/i_kcp.c -lws2_32
```

## License
MIT

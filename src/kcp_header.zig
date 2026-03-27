const std = @import("std");

pub const KcpHeader = struct {
    conv: u32,
    cmd: u8,
    frg: u8,
    wnd: u16,
    ts: u32,
    sn: u32,
    una: u32,
    len: u32,

    pub const SIZE: usize = 24;

    pub fn encode(self: KcpHeader, buf: []u8) void {
        std.mem.writeInt(u32, buf[0..4], self.conv, .little);
        buf[4] = self.cmd;
        buf[5] = self.frg;
        std.mem.writeInt(u16, buf[6..8], self.wnd, .little);
        std.mem.writeInt(u32, buf[8..12], self.ts, .little);
        std.mem.writeInt(u32, buf[12..16], self.sn, .little);
        std.mem.writeInt(u32, buf[16..20], self.una, .little);
        std.mem.writeInt(u32, buf[20..24], self.len, .little);
    }

    pub fn decode(buf: []const u8) KcpHeader {
        return KcpHeader{
            .conv = std.mem.readInt(u32, buf[0..4], .little),
            .cmd = buf[4],
            .frg = buf[5],
            .wnd = std.mem.readInt(u16, buf[6..8], .little),
            .ts = std.mem.readInt(u32, buf[8..12], .little),
            .sn = std.mem.readInt(u32, buf[12..16], .little),
            .una = std.mem.readInt(u32, buf[16..20], .little),
            .len = std.mem.readInt(u32, buf[20..24], .little),
        };
    }
};

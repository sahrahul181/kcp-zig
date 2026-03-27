const std = @import("std");

pub const Segment = struct {
    conv: u32 = 0,
    cmd: u8 = 0,
    frg: u8 = 0,
    wnd: u16 = 0,
    ts: u32 = 0,
    sn: u32 = 0,
    una: u32 = 0,
    resend_ts: u32 = 0,
    rto: u32 = 0,
    fastack: u32 = 0,
    xmit: u32 = 0,
    data: std.ArrayList(u8) = .{},

    // Intrusive pointers for SegmentList
    prev: ?*Segment = null,
    next: ?*Segment = null,

    pub fn deinit(self: *Segment, allocator: std.mem.Allocator) void {
        self.data.deinit(allocator);
        self.* = undefined;
    }

    pub fn reset(self: *Segment) void {
        self.conv = 0;
        self.cmd = 0;
        self.frg = 0;
        self.wnd = 0;
        self.ts = 0;
        self.sn = 0;
        self.una = 0;
        self.resend_ts = 0;
        self.rto = 0;
        self.fastack = 0;
        self.xmit = 0;
        // Don't clear ArrayList items here, wait for usage to avoid re-allocation
    }
};

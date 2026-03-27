const std = @import("std");
const KcpHeader = @import("kcp_header.zig").KcpHeader;
const Segment = @import("segment.zig").Segment;

/// A simple intrusive doubly linked list for Segment
pub const SegmentList = struct {
    first: ?*Segment = null,
    last: ?*Segment = null,
    len: u32 = 0,

    pub fn append(self: *SegmentList, seg: *Segment) void {
        seg.next = null;
        seg.prev = self.last;
        if (self.last) |last| {
            last.next = seg;
        } else {
            self.first = seg;
        }
        self.last = seg;
        self.len += 1;
    }

    pub fn prepend(self: *SegmentList, seg: *Segment) void {
        seg.prev = null;
        seg.next = self.first;
        if (self.first) |first| {
            first.prev = seg;
        } else {
            self.last = seg;
        }
        self.first = seg;
        self.len += 1;
    }

    pub fn insertAfter(self: *SegmentList, existing: *Segment, new: *Segment) void {
        new.prev = existing;
        new.next = existing.next;
        if (existing.next) |next| {
            next.prev = new;
        } else {
            self.last = new;
        }
        existing.next = new;
        self.len += 1;
    }

    pub fn remove(self: *SegmentList, seg: *Segment) void {
        if (seg.prev) |prev| {
            prev.next = seg.next;
        } else {
            self.first = seg.next;
        }
        if (seg.next) |next| {
            next.prev = seg.prev;
        } else {
            self.last = seg.prev;
        }
        seg.prev = null;
        seg.next = null;
        self.len -= 1;
    }

    pub fn popFirst(self: *SegmentList) ?*Segment {
        const seg = self.first orelse return null;
        self.remove(seg);
        return seg;
    }

    pub fn clear(self: *SegmentList) void {
        self.first = null;
        self.last = null;
        self.len = 0;
    }
};

pub const KcpError = error{
    OutOfMemory,
    InvalidPacket,
    NoMoreData,
    BufferTooSmall,
};

pub const OutputCallback = *const fn (buf: []const u8, user: ?*const anyopaque) void;

pub const Kcp = struct {
    conv: u32,
    mtu: u32,
    mss: u32,
    state: i32,

    snd_una: u32,
    snd_nxt: u32,
    rcv_nxt: u32,

    ts_recent: u32,
    ts_lastack: u32,
    ssthresh: u32,
    rx_rttvar: i32,
    rx_srtt: i32,
    rx_rto: i32,
    rx_minrto: i32,

    snd_wnd: u32,
    rcv_wnd: u32,
    rmt_wnd: u32,
    cwnd: u32,
    probe: u32,

    interval: u32,
    ts_flush: u32,
    xmit: u32,

    nodelay: bool,
    updated: bool,

    ts_probe: u32,
    probe_wait: u32,

    dead_link: u32,
    incr: u32,

    snd_queue: SegmentList,
    snd_buf: SegmentList,
    rcv_queue: SegmentList,
    rcv_buf: SegmentList,
    acklist: std.ArrayListUnmanaged(AckItem),

    // Improvements: Added pool and options
    segment_pool: SegmentList,
    stream: bool,
    nocwnd: bool,
    fastresend: i32,

    mutex: std.Thread.Mutex = .{},

    buffer: []u8,
    user: ?*const anyopaque,
    output: OutputCallback,

    allocator: std.mem.Allocator,

    pub const AckItem = struct {
        sn: u32,
        ts: u32,
    };

    pub const IKCP_CMD_PUSH: u8 = 81;
    pub const IKCP_CMD_ACK: u8 = 82;
    pub const IKCP_CMD_WASK: u8 = 83;
    pub const IKCP_CMD_WINS: u8 = 84;

    pub const IKCP_ASK_SEND: u32 = 1;
    pub const IKCP_ASK_TELL: u32 = 2;

    pub fn init(conv: u32, user: ?*const anyopaque, output: OutputCallback, allocator: std.mem.Allocator) !Kcp {
        const mtu = 1400;
        return Kcp{
            .conv = conv,
            .mtu = mtu,
            .mss = mtu - @as(u32, @intCast(KcpHeader.SIZE)),
            .state = 0,
            .snd_una = 0,
            .snd_nxt = 0,
            .rcv_nxt = 0,
            .ts_recent = 0,
            .ts_lastack = 0,
            .ssthresh = 2,
            .rx_rttvar = 0,
            .rx_srtt = 0,
            .rx_rto = 200,
            .rx_minrto = 100,
            .snd_wnd = 32,
            .rcv_wnd = 32,
            .rmt_wnd = 32,
            .cwnd = 0,
            .probe = 0,
            .interval = 100,
            .ts_flush = 100,
            .xmit = 0,
            .nodelay = false,
            .updated = false,
            .ts_probe = 0,
            .probe_wait = 0,
            .dead_link = 20,
            .incr = 0,
            .snd_queue = .{},
            .snd_buf = .{},
            .rcv_queue = .{},
            .rcv_buf = .{},
            .acklist = .{},
            .segment_pool = .{},
            .stream = false,
            .nocwnd = false,
            .fastresend = 0,
            .buffer = try allocator.alloc(u8, @as(usize, @intCast(mtu + KcpHeader.SIZE)) * 3),
            .user = user,
            .output = output,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Kcp) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        inline for (.{ &self.snd_queue, &self.snd_buf, &self.rcv_queue, &self.rcv_buf, &self.segment_pool }) |q| {
            while (q.popFirst()) |seg| {
                seg.deinit(self.allocator);
                self.allocator.destroy(seg);
            }
        }
        self.acklist.deinit(self.allocator);
        self.allocator.free(self.buffer);
    }

    pub fn setWndSize(self: *Kcp, snd_wnd: u32, rcv_wnd: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (snd_wnd > 0) self.snd_wnd = snd_wnd;
        if (rcv_wnd > 0) self.rcv_wnd = rcv_wnd;
    }

    pub fn setNoDelay(self: *Kcp, nodelay: bool, interval: u32, resend: i32, nc: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.nodelay = nodelay;
        if (nodelay) {
            self.rx_minrto = 30;
        } else {
            self.rx_minrto = 100;
        }
        if (interval >= 10 and interval <= 5000) {
            self.interval = interval;
        }
        self.fastresend = resend;
        self.nocwnd = nc;
    }

    fn segment_new(self: *Kcp, size: usize) !*Segment {
        var seg = self.segment_pool.popFirst();
        if (seg == null) {
            seg = try self.allocator.create(Segment);
            seg.?.* = .{};
        } else {
            seg.?.reset();
        }
        // Ensure data buffer is large enough
        if (seg.?.data.items.len < size) {
            try seg.?.data.ensureTotalCapacity(self.allocator, size);
        }
        return seg.?;
    }

    fn segment_delete(self: *Kcp, seg: *Segment) void {
        // Hardening: avoid memory bloating the pool by shrinking segments that 
        // grew excessively large (e.g. from rare oversized packets)
        if (seg.data.capacity > self.mtu * 2) {
            seg.data.deinit(self.allocator);
            seg.data = .{};
        } else {
            seg.data.clearRetainingCapacity();
        }
        self.segment_pool.append(seg);
    }

    fn peekSize(self: *Kcp) i32 {
        if (self.rcv_queue.first == null) return -1;
        const seg = self.rcv_queue.first.?;
        if (seg.frg == 0) return @as(i32, @intCast(seg.data.items.len));

        if (self.rcv_queue.len < seg.frg + 1) return -1;

        var full_len: usize = 0;
        var it = self.rcv_queue.first;
        while (it) |node| {
            full_len += node.data.items.len;
            if (node.frg == 0) break;
            it = node.next;
        }
        return @as(i32, @intCast(full_len));
    }

    pub fn recv(self: *Kcp, buf: []u8) KcpError!usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.rcv_queue.first == null) return KcpError.NoMoreData;

        const peek_len = self.peekSize();
        if (peek_len < 0) return KcpError.NoMoreData;
        const upeek_len = @as(usize, @intCast(peek_len));

        if (buf.len < upeek_len) return KcpError.BufferTooSmall;

        var pos: usize = 0;
        const recover = self.rcv_queue.len >= self.rcv_wnd;

        while (self.rcv_queue.popFirst()) |seg| {
            @memcpy(buf[pos .. pos + seg.data.items.len], seg.data.items);
            pos += seg.data.items.len;
            const frg = seg.frg;
            self.segment_delete(seg);
            if (frg == 0) break;
        }

        // move from rcv_buf to rcv_queue
        while (self.rcv_buf.first) |seg| {
            if (seg.sn == self.rcv_nxt and self.rcv_queue.len < self.rcv_wnd) {
                self.rcv_buf.remove(seg);
                self.rcv_queue.append(seg);
                self.rcv_nxt += 1;
            } else {
                break;
            }
        }

        // fast recover
        if (self.rcv_queue.len < self.rcv_wnd and recover) {
            self.probe |= IKCP_ASK_TELL;
        }

        return upeek_len;
    }

    pub fn send(self: *Kcp, buf: []const u8) KcpError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.mss == 0) return;
        var pos: usize = 0;
        var count: usize = 0;
        
        if (buf.len <= self.mss) {
            count = 1;
        } else {
            count = (buf.len + self.mss - 1) / self.mss;
        }

        if (count > @as(usize, 255)) return KcpError.InvalidPacket;
        if (count == 0) count = 1;

        for (0..count) |i| {
            const size = if (buf.len - pos > self.mss) self.mss else buf.len - pos;
            const seg = try self.segment_new(size);
            if (buf.len > 0) {
                try seg.data.appendSlice(self.allocator, buf[pos .. pos + size]);
            }
            seg.frg = if (self.stream) 0 else @as(u8, @intCast(count - i - 1));
            self.snd_queue.append(seg);
            pos += size;
        }
    }

    fn update_ack(self: *Kcp, rtt: i32) void {
        if (self.rx_srtt == 0) {
            self.rx_srtt = rtt;
            self.rx_rttvar = @divTrunc(rtt, 2);
        } else {
            const delta = if (rtt > self.rx_srtt) rtt - self.rx_srtt else self.rx_srtt - rtt;
            self.rx_rttvar = @divTrunc(3 * self.rx_rttvar + delta, 4);
            self.rx_srtt = @divTrunc(7 * self.rx_srtt + rtt, 8);
            if (self.rx_srtt < 1) self.rx_srtt = 1;
        }
        const rto = self.rx_srtt + @max(@as(i32, @intCast(self.interval)), 4 * self.rx_rttvar);
        self.rx_rto = std.math.clamp(rto, self.rx_minrto, 60000);
    }

    fn shrink_buf(self: *Kcp) void {
        if (self.snd_buf.first) |seg| {
            self.snd_una = seg.sn;
        } else {
            self.snd_una = self.snd_nxt;
        }
    }

    fn parse_ack(self: *Kcp, sn: u32) void {
        if (sn < self.snd_una or sn >= self.snd_nxt) return;

        var it = self.snd_buf.first;
        while (it) |seg| {
            const next = seg.next;
            if (sn == seg.sn) {
                self.snd_buf.remove(seg);
                self.segment_delete(seg);
                break;
            } else if (sn < seg.sn) {
                break;
            }
            it = next;
        }
    }

    fn parse_una(self: *Kcp, una: u32) void {
        while (self.snd_buf.first) |seg| {
            if (una > seg.sn) {
                self.snd_buf.remove(seg);
                self.segment_delete(seg);
            } else {
                break;
            }
        }
    }

    fn parse_fastack(self: *Kcp, sn: u32, ts: u32) void {
        if (sn < self.snd_una or sn >= self.snd_nxt) return;
        var it = self.snd_buf.first;
        while (it) |seg| {
            if (sn < seg.sn) break;
            if (sn != seg.sn and ts >= seg.ts) {
                seg.fastack += 1;
            }
            it = seg.next;
        }
    }

    fn parse_data(self: *Kcp, new_seg: *Segment) !void {
        const sn = new_seg.sn;
        if (sn >= self.rcv_nxt + self.rcv_wnd or sn < self.rcv_nxt) {
            self.segment_delete(new_seg);
            return;
        }

        var repeat = false;
        var it = self.rcv_buf.last;
        while (it) |seg| {
            if (seg.sn == sn) {
                repeat = true;
                break;
            }
            if (sn > seg.sn) break;
            it = seg.prev;
        }

        if (!repeat) {
            var insert_pos: ?*Segment = null;
            var sit = self.rcv_buf.last;
            while (sit) |seg| {
                if (sn > seg.sn) {
                    insert_pos = seg;
                    break;
                }
                sit = seg.prev;
            }
            if (insert_pos) |pos| {
                self.rcv_buf.insertAfter(pos, new_seg);
            } else {
                self.rcv_buf.prepend(new_seg);
            }
        } else {
            self.segment_delete(new_seg);
        }

        // move from rcv_buf to rcv_queue
        while (self.rcv_buf.first) |seg| {
            if (seg.sn == self.rcv_nxt and self.rcv_queue.len < self.rcv_wnd) {
                self.rcv_buf.remove(seg);
                self.rcv_queue.append(seg);
                self.rcv_nxt += 1;
            } else {
                break;
            }
        }
    }

    pub fn input(self: *Kcp, data: []const u8, current: u32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (data.len < KcpHeader.SIZE) return KcpError.InvalidPacket;

        var pos: usize = 0;
        var max_una: u32 = self.snd_una;
        var latest_ts: u32 = 0;
        var flag = false;

        while (pos + KcpHeader.SIZE <= data.len) {
            const header = KcpHeader.decode(data[pos .. pos + KcpHeader.SIZE]);
            pos += KcpHeader.SIZE;

            if (header.conv != self.conv) return KcpError.InvalidPacket;
            if (pos + header.len > data.len) return KcpError.InvalidPacket;

            self.rmt_wnd = header.wnd;
            self.parse_una(header.una);
            self.shrink_buf();

            if (header.cmd == IKCP_CMD_ACK) {
                if (current >= header.ts) {
                    self.update_ack(@as(i32, @intCast(current - header.ts)));
                }
                self.parse_ack(header.sn);
                self.shrink_buf();
                if (!flag) {
                    flag = true;
                    max_una = header.sn;
                    latest_ts = header.ts;
                } else if (header.sn > max_una) {
                    max_una = header.sn;
                    latest_ts = header.ts;
                }
            } else if (header.cmd == IKCP_CMD_PUSH) {
                if (header.sn < self.rcv_nxt + self.rcv_wnd) {
                    try self.ack_push(header.sn, header.ts);
                    if (header.sn >= self.rcv_nxt) {
                        const seg = try self.segment_new(header.len);
                        seg.conv = header.conv;
                        seg.cmd = header.cmd;
                        seg.frg = header.frg;
                        seg.wnd = header.wnd;
                        seg.ts = header.ts;
                        seg.sn = header.sn;
                        seg.una = header.una;
                        if (header.len > 0) {
                            try seg.data.appendSlice(self.allocator, data[pos .. pos + header.len]);
                        }
                        try self.parse_data(seg);
                    }
                }
            } else if (header.cmd == IKCP_CMD_WASK) {
                self.probe |= IKCP_ASK_TELL;
            } else if (header.cmd == IKCP_CMD_WINS) {
                // window size in header.wnd, treated in parse_una
            } else {
                return KcpError.InvalidPacket;
            }

            pos += header.len;
        }

        if (flag) {
            self.parse_fastack(max_una, latest_ts);
        }

        // cwnd update logic
        if (self.snd_una > max_una and !self.nocwnd) {
            if (self.cwnd < self.rmt_wnd) {
                const mss = self.mss;
                if (self.cwnd < self.ssthresh) {
                    self.cwnd += 1;
                    self.incr += mss;
                } else {
                    if (self.incr < mss) self.incr = mss;
                    self.incr += (mss * mss) / self.incr + (mss / 16);
                    if ((self.cwnd + 1) * mss <= self.incr) {
                        self.cwnd = (self.incr + mss - 1) / mss;
                    }
                }
                if (self.cwnd > self.rmt_wnd) {
                    self.cwnd = self.rmt_wnd;
                    self.incr = self.cwnd * mss;
                }
            }
        }
    }

    fn ack_push(self: *Kcp, sn: u32, ts: u32) !void {
        try self.acklist.append(self.allocator, .{ .sn = sn, .ts = ts });
    }

    pub fn update(self: *Kcp, current: u32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.updated) {
            self.updated = true;
            self.ts_flush = current;
        }

        var slap = @as(i32, @intCast(current)) - @as(i32, @intCast(self.ts_flush));
        if (slap >= 10000 or slap < -10000) {
            self.ts_flush = current;
            slap = 0;
        }

        if (slap >= 0) {
            try self.flushInternal(current);
            self.ts_flush += self.interval;
            if (@as(i32, @intCast(current)) - @as(i32, @intCast(self.ts_flush)) >= 0) {
                self.ts_flush = current + self.interval;
            }
        }
    }

    pub fn flush(self: *Kcp, current: u32) !void {
        // We use lock_try/lock because update() also calls flush. 
        // In Zig, we can't easily check for recursive lock, so we use internal _flush
        // but if flush() is called publicly, we lock.
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.flushInternal(current);
    }

    fn flushInternal(self: *Kcp, current: u32) !void {
        var header = KcpHeader{
            .conv = self.conv,
            .cmd = IKCP_CMD_PUSH,
            .frg = 0,
            .wnd = @as(u16, @intCast(self.rcv_wnd_unused())),
            .ts = current,
            .sn = 0,
            .una = self.rcv_nxt,
            .len = 0,
        };

        var ptr: usize = 0;

        // 1. flush acks
        for (self.acklist.items) |ack| {
            if (ptr + KcpHeader.SIZE > self.mtu) {
                self.output(self.buffer[0..ptr], self.user);
                ptr = 0;
            }
            header.sn = ack.sn;
            header.ts = ack.ts;
            header.cmd = IKCP_CMD_ACK;
            header.encode(self.buffer[ptr .. ptr + KcpHeader.SIZE]);
            ptr += KcpHeader.SIZE;
        }
        self.acklist.clearRetainingCapacity();

        // 2. window probing
        if (self.rmt_wnd == 0) {
            if (self.probe_wait == 0) {
                self.probe_wait = 7000;
                self.ts_probe = current + self.probe_wait;
            } else if (current >= self.ts_probe) {
                if (self.probe_wait < 7000) self.probe_wait = 7000;
                self.probe_wait += self.probe_wait / 2;
                if (self.probe_wait > 120000) self.probe_wait = 120000;
                self.ts_probe = current + self.probe_wait;
                self.probe |= IKCP_ASK_SEND;
            }
        } else {
            self.ts_probe = 0;
            self.probe_wait = 0;
        }

        if ((self.probe & IKCP_ASK_SEND) != 0) {
            header.cmd = IKCP_CMD_WASK;
            if (ptr + KcpHeader.SIZE > self.mtu) {
                self.output(self.buffer[0..ptr], self.user);
                ptr = 0;
            }
            header.encode(self.buffer[ptr .. ptr + KcpHeader.SIZE]);
            ptr += KcpHeader.SIZE;
        }

        if ((self.probe & IKCP_ASK_TELL) != 0) {
            header.cmd = IKCP_CMD_WINS;
            if (ptr + KcpHeader.SIZE > self.mtu) {
                self.output(self.buffer[0..ptr], self.user);
                ptr = 0;
            }
            header.encode(self.buffer[ptr .. ptr + KcpHeader.SIZE]);
            ptr += KcpHeader.SIZE;
        }
        self.probe = 0;

        // 3. move from snd_queue to snd_buf
        const cwnd = if (self.nocwnd) self.rmt_wnd else @min(self.snd_wnd, if (self.rmt_wnd > 0) self.rmt_wnd else 1);
        while (self.snd_nxt < self.snd_una + cwnd) {
            const seg = self.snd_queue.popFirst() orelse break;
            seg.conv = self.conv;
            seg.cmd = IKCP_CMD_PUSH;
            seg.wnd = header.wnd;
            seg.ts = current;
            seg.sn = self.snd_nxt;
            seg.una = self.rcv_nxt;
            seg.resend_ts = current;
            seg.rto = @as(u32, @intCast(self.rx_rto));
            seg.fastack = 0;
            seg.xmit = 0;
            self.snd_buf.append(seg);
            self.snd_nxt += 1;
        }

        // 4. flush snd_buf
        const resent = if (self.fastresend > 0) @as(u32, @intCast(self.fastresend)) else 0xFFFFFFFF;
        var it = self.snd_buf.first;
        while (it) |seg| {
            var needs_send = false;
            if (seg.xmit == 0) {
                needs_send = true;
                seg.xmit += 1;
                seg.rto = @as(u32, @intCast(self.rx_rto));
                seg.resend_ts = current + seg.rto;
            } else if (current >= seg.resend_ts) {
                needs_send = true;
                seg.xmit += 1;
                if (!self.nodelay) {
                    seg.rto += @as(u32, @intCast(self.rx_rto));
                } else {
                    seg.rto += @divTrunc(@as(u32, @intCast(self.rx_rto)), 2);
                }
                seg.resend_ts = current + seg.rto;
            } else if (seg.fastack >= resent) {
                needs_send = true;
                seg.xmit += 1;
                seg.fastack = 0;
                seg.resend_ts = current + seg.rto;
            }

            if (needs_send) {
                if (ptr + KcpHeader.SIZE + seg.data.items.len > self.mtu) {
                    self.output(self.buffer[0..ptr], self.user);
                    ptr = 0;
                }
                header.cmd = seg.cmd;
                header.frg = seg.frg;
                header.sn = seg.sn;
                header.ts = current; // update ts for retransmission
                header.len = @as(u32, @intCast(seg.data.items.len));
                header.encode(self.buffer[ptr .. ptr + KcpHeader.SIZE]);
                ptr += KcpHeader.SIZE;
                @memcpy(self.buffer[ptr .. ptr + seg.data.items.len], seg.data.items);
                ptr += seg.data.items.len;
                if (seg.xmit >= self.dead_link) {
                    self.state = -1;
                }
            }
            it = seg.next;
        }

        if (ptr > 0) {
            self.output(self.buffer[0..ptr], self.user);
        }
    }

    fn rcv_wnd_unused(self: *Kcp) i32 {
        if (self.rcv_queue.len < self.rcv_wnd) {
            return @as(i32, @intCast(self.rcv_wnd - self.rcv_queue.len));
        }
        return 0;
    }
};

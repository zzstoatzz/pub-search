//! Zig 0.16 compatibility helpers.
//! Replaces removed APIs: posix.getenv, std.time.microTimestamp,
//! std.time.timestamp, std.Thread.sleep, std.Thread.Mutex/Condition.
//! Also provides global Io access for http.Client and other networking.

const std = @import("std");

// --- global Io (set once in main, used by http.Client consumers) ---

var global_io: ?std.Io = null;

pub fn initIo(io: std.Io) void {
    global_io = io;
}

pub fn getIo() std.Io {
    return global_io.?;
}

// --- environment variables ---

pub fn getenv(key: [*:0]const u8) ?[]const u8 {
    return if (std.c.getenv(key)) |p| std.mem.span(p) else null;
}

// --- timestamps ---

pub fn microTimestamp() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1_000);
}

pub fn timestamp() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @as(i64, ts.sec);
}

// --- sleep ---

pub fn sleep(ns: u64) void {
    var req: std.c.timespec = .{
        .sec = @intCast(@divFloor(ns, std.time.ns_per_s)),
        .nsec = @intCast(@mod(ns, std.time.ns_per_s)),
    };
    while (true) {
        var rem: std.c.timespec = undefined;
        const rc = std.c.nanosleep(&req, &rem);
        if (rc == 0) return;
        // EINTR: interrupted, retry with remaining time
        req = rem;
    }
}

pub fn sleepSecs(secs: u64) void {
    sleep(secs * std.time.ns_per_s);
}

pub fn sleepMs(ms: u64) void {
    sleep(ms * std.time.ns_per_ms);
}

// --- mutex (pthread-based, works without Io) ---

pub const Mutex = struct {
    inner: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    pub fn lock(self: *Mutex) void {
        _ = std.c.pthread_mutex_lock(&self.inner);
    }

    pub fn unlock(self: *Mutex) void {
        _ = std.c.pthread_mutex_unlock(&self.inner);
    }

    pub fn tryLock(self: *Mutex) bool {
        return std.c.pthread_mutex_trylock(&self.inner) == .SUCCESS;
    }
};

// --- condition variable ---

pub const Condition = struct {
    inner: std.c.pthread_cond_t = std.c.PTHREAD_COND_INITIALIZER,

    pub fn wait(self: *Condition, mutex: *Mutex) void {
        _ = std.c.pthread_cond_wait(&self.inner, &mutex.inner);
    }

    pub fn signal(self: *Condition) void {
        _ = std.c.pthread_cond_signal(&self.inner);
    }

    pub fn broadcast(self: *Condition) void {
        _ = std.c.pthread_cond_broadcast(&self.inner);
    }
};

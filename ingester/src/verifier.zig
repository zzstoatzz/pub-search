//! commit verification — DID signing-key resolution + signature/MST check.
//!
//! simplified from zlay's validator (zat.dev/zlay src/internal/validator.zig):
//! zlay validates the whole relay firehose so it needs an LRU cache and
//! background resolver threads; we only verify commits that touch our tracked
//! collections (~tens per minute, a few thousand distinct authors total), so a
//! plain grow-only cache and a synchronous resolve on first encounter per DID
//! is fine — the firehose read loop stalls one PLC roundtrip per new author
//! and we resume from the persisted cursor if anything goes wrong.

const std = @import("std");
const Io = std.Io;
const zat = @import("zat");
const logfire = @import("logfire");

/// decoded signing key, ready for verification (mirrors zlay's CachedKey).
const CachedKey = struct {
    key_type: zat.multicodec.KeyType,
    raw: [33]u8, // compressed public key (secp256k1 or p256)
    len: u8,
};

/// how a commit passed (or failed) verification.
pub const Verdict = enum {
    /// signature + MST diff inversion both check out.
    full,
    /// signature checks out but the MST diff math doesn't — non-canonical
    /// repo implementations (bridgy fed) and occasional legit-PDS bursts
    /// land here. authorship is still proven, so records are emitted; the
    /// backend's reconciler already classifies bridgy separately.
    sig_only,
    /// signature verification failed (or no key / no blocks) — never emitted.
    rejected,
};

pub const Verifier = struct {
    allocator: std.mem.Allocator,
    resolver: zat.DidResolver,
    cache: std.StringHashMapUnmanaged(CachedKey) = .empty,
    verified: u64 = 0,
    sig_only: u64 = 0,
    rejected: u64 = 0,
    unresolvable: u64 = 0,
    last_err: []const u8 = "none",

    pub fn init(io: Io, allocator: std.mem.Allocator) Verifier {
        return .{
            .allocator = allocator,
            .resolver = zat.DidResolver.initWithOptions(io, allocator, .{ .keep_alive = true }),
        };
    }

    pub fn deinit(self: *Verifier) void {
        var it = self.cache.iterator();
        while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.cache.deinit(self.allocator);
        self.resolver.deinit();
    }

    /// verify a commit's CAR bytes against the repo's signing key. callers
    /// must not emit records from commits that return `.rejected`.
    pub fn verifyCommit(self: *Verifier, commit: zat.firehose.CommitEvent) Verdict {
        if (commit.blocks.len == 0) {
            // no CAR to verify (e.g. legacy tooBig frames strip blocks).
            self.rejected += 1;
            logfire.warn("verifier: no blocks for did={s} seq={d} too_big={}", .{ commit.repo, commit.seq, commit.too_big });
            return .rejected;
        }

        const key = self.signingKey(commit.repo, false) orelse {
            self.unresolvable += 1;
            return .rejected;
        };

        if (self.verifyWithKey(commit, key)) |verdict| return self.count(verdict);

        // signature failure can mean the key rotated since we cached it:
        // re-resolve once and retry before rejecting (sync spec guidance,
        // same as zlay's evict + re-resolve, but inline since we're low-volume).
        const fresh = self.signingKey(commit.repo, true) orelse {
            self.unresolvable += 1;
            return .rejected;
        };
        if (self.verifyWithKey(commit, fresh)) |verdict| return self.count(verdict);

        self.rejected += 1;
        logfire.warn("verifier: rejected commit did={s} seq={d} rev={s} err={s}", .{ commit.repo, commit.seq, commit.rev, self.last_err });
        return .rejected;
    }

    fn count(self: *Verifier, verdict: Verdict) Verdict {
        switch (verdict) {
            .full => self.verified += 1,
            .sig_only => self.sig_only += 1,
            .rejected => unreachable,
        }
        return verdict;
    }

    /// null = signature failure (caller retries with a fresh key).
    fn verifyWithKey(self: *Verifier, commit: zat.firehose.CommitEvent, key: CachedKey) ?Verdict {
        const public_key = zat.multicodec.PublicKey{
            .key_type = key.key_type,
            .raw = key.raw[0..key.len],
        };
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        // firehose frames carry a *diff* CAR (commit block + changed MST nodes
        // only), so verifyCommitCar's full MST walk can never succeed here.
        // verifyCommitDiff is the relay-grade check: signature over the commit,
        // then invert the frame's ops against the partial MST and require the
        // resulting root to match prev_data (sync 1.1).
        const ops = commit.toMstOperations(alloc) catch return null;
        const prev_data: ?[]const u8 = if (commit.prev_data) |pd| pd.raw else null;
        _ = zat.verifyCommitDiff(alloc, commit.blocks, ops, prev_data, public_key, .{
            .expected_did = commit.repo,
            .skip_inversion = prev_data == null,
        }) catch |err| {
            self.last_err = @errorName(err);
            return switch (err) {
                // MST-math failures surface only after the signature already
                // verified (step 4 precedes MST load/inversion), so authorship
                // is proven — non-canonical repos (bridgy fed) and occasional
                // legit-PDS bursts land here.
                error.PrevDataMismatch,
                error.InversionMismatch,
                error.MstRootMismatch,
                error.PartialTree,
                error.DuplicatePath,
                error.InvalidMstNode,
                => .sig_only,
                // signature / structural failures: let the caller retry with
                // a freshly-resolved key, then reject.
                else => null,
            };
        };
        return .full;
    }

    /// cached signing key for a DID, resolving via PLC/did:web on miss.
    /// `force` re-resolves even on a cache hit (key rotation path).
    fn signingKey(self: *Verifier, did: []const u8, force: bool) ?CachedKey {
        if (!force) {
            if (self.cache.get(did)) |cached| return cached;
        }

        const parsed = zat.Did.parse(did) orelse return null;
        var doc = self.resolver.resolve(parsed) catch |err| {
            logfire.warn("verifier: DID resolve failed for {s}: {s}", .{ did, @errorName(err) });
            return null;
        };
        defer doc.deinit();

        const vm = doc.signingKey() orelse return null;
        const key_bytes = zat.multibase.decode(self.allocator, vm.public_key_multibase) catch return null;
        defer self.allocator.free(key_bytes);
        const public_key = zat.multicodec.parsePublicKey(key_bytes) catch return null;
        if (public_key.raw.len > 33) return null;

        var cached = CachedKey{
            .key_type = public_key.key_type,
            .raw = undefined,
            .len = @intCast(public_key.raw.len),
        };
        @memcpy(cached.raw[0..public_key.raw.len], public_key.raw);

        const gop = self.cache.getOrPut(self.allocator, did) catch return cached;
        if (!gop.found_existing) {
            gop.key_ptr.* = self.allocator.dupe(u8, did) catch {
                _ = self.cache.remove(did);
                return cached;
            };
        }
        gop.value_ptr.* = cached;
        return cached;
    }

    /// drop a DID's cached key (on #identity events — key may have rotated).
    pub fn evict(self: *Verifier, did: []const u8) void {
        if (self.cache.fetchRemove(did)) |kv| self.allocator.free(kv.key);
    }
};

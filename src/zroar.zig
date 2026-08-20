// Copyright 2026 Manish R Jain
// SPDX-License-Identifier: Apache-2.0

//! zroar — serialized roaring bitmaps over u64 values.
//!
//! A bitmap is one flat, 8-byte-aligned buffer of u16s: a keys node followed by
//! containers. That buffer *is* the serialized form, so `fromBuffer` is O(1)
//! and allocation-free.
//!
//! Ported from https://github.com/dgraph-io/sroar; see DESIGN.md.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

// The on-disk format is little-endian by definition. On little-endian targets
// (every supported one) reinterpreting the buffer IS the encoding, so this
// costs nothing. Big-endian targets would corrupt data silently; refuse them.
comptime {
    if (builtin.target.cpu.arch.endian() != .little)
        @compileError("zroar's on-disk format is little-endian; " ++
            "big-endian targets are unsupported");
}

const container = @import("container.zig");
const keys_mod = @import("keys.zig");
const stats = @import("stats.zig");
const zero = @import("zero.zig").zero;

pub const Keys = keys_mod.Keys;
/// Optional counters for the memory movement this library does; off unless
/// the root source file declares `pub const zroar_track_stats = true`.
pub const Stats = stats;
pub const Iterator = @import("iterator.zig").Iterator;

/// The high 48 bits of a value select its container.
pub const key_mask = keys_mod.key_mask;

/// The serialized layout's version, stamped into the first two bytes of every
/// buffer. `fromBuffer` accepts only buffers carrying this value.
pub const format_version = keys_mod.format_version;

/// Slice types for zroar buffers and containers. The 8-byte alignment is a
/// correctness requirement, not a hint: a buffer's keys node and a bitmap
/// container's payload are both viewed as `[]u64`. The trailing number is the
/// element width, not the alignment.
pub const AlignedU8 = []align(8) u8;
pub const AlignedConstU8 = []align(8) const u8;
pub const AlignedU16 = []align(8) u16;

/// Key/offset pairs a freshly initialized bitmap has room for.
const init_num_keys: usize = 2;

/// The keys node grows by doubling, capped at this many u16s per step. The cap
/// is a multiple of 4 so the node size stays 8-byte aligned. Public only so the
/// test suite can assert the capped step without restating the number.
pub const max_node_growth: usize = 65532;

/// Growing a container that is not last in the buffer moves it to the end
/// rather than memmoving everything behind it; the slot it leaves behind is
/// dead space until `cleanup` runs. Mutating ops trigger that cleanup
/// themselves once dead slots exceed a quarter of the buffer, which bounds
/// the waste a build-heavy workload can accumulate. Public only so the test
/// suite can assert the bound without restating the number.
pub const max_dead_divisor: usize = 4;

/// The keys node header (node size, number of keys), in u16 units.
const node_header_size: usize = keys_mod.index_node_start * 4;

/// One (key, offset) pair of the keys node, in u16 units.
const key_pair_size: usize = 8;

/// Every bitmap has a keys node with room for at least two keys plus key 0's
/// minimum-size container, so no valid buffer is smaller than this. Public only
/// so the test suite can build buffers on either side of the threshold.
pub const min_buffer_bytes: usize =
    2 * (4 * (2 * init_num_keys + 2) + container.min_size);

pub const Bitmap = struct {
    /// The in-use region of the buffer, in u16 units.
    data: AlignedU16,
    /// Allocated capacity in u16 units. Equals data.len for a borrowed buffer.
    cap: usize,
    /// False for a buffer handed to us by `fromBuffer`; true once we own it.
    /// Flips on the first mutation, which copies the buffer out beforehand,
    /// so the caller's buffer is never written to. See `ensureOwned`.
    owned: bool,
    /// Dead u16s abandoned by container relocation; see `max_dead_divisor`.
    dead: usize = 0,
    allocator: std.mem.Allocator,
    /// Optional per-bitmap counters for the memory this bitmap moves around.
    /// Zero-bit and inert unless the root source file declares
    /// `pub const zroar_track_stats = true`; see `stats.zig`.
    counters: stats.Sink = .{},

    /// Creates an empty bitmap. The caller owns it and must call `deinit`.
    pub fn init(allocator: std.mem.Allocator) !Bitmap {
        return initWithKeys(allocator, init_num_keys);
    }

    /// Releases the buffer if this bitmap owns it. Safe on a borrowed bitmap.
    pub fn deinit(self: *Bitmap) void {
        if (self.owned) self.allocator.free(self.data.ptr[0..self.cap]);
        self.* = undefined;
    }

    fn initWithKeys(allocator: std.mem.Allocator, num_keys: usize) !Bitmap {
        assert(num_keys >= 2);
        // Two u64s of node header plus a (key, offset) pair per key.
        const node_size = 4 * (2 * num_keys + 2);
        const cap = node_size + container.min_size;

        const buf = try allocator.alignedAlloc(u16, .@"8", cap);
        zero(buf);

        var bm = Bitmap{
            .data = buf.ptr[0..node_size],
            .cap = cap,
            .owned = true,
            .allocator = allocator,
        };
        bm.setNodeSize(node_size);

        // Key 0 always exists: a zeroed key slot and a legitimate zero key are
        // otherwise indistinguishable. Nothing may ever remove it.
        const offset = try bm.newContainer(container.min_size);
        const ks = bm.keys();
        ks.setNumKeys(1);
        ks.setKeyAt(0, 0);
        ks.setValAt(0, offset);
        return bm;
    }

    // -----------------------------------------------------------------------
    // Buffer machinery
    // -----------------------------------------------------------------------

    /// Internal: a view of the keys node. Never hold one across a call that can
    /// grow the buffer — growth reallocates and the view dangles.
    pub fn keys(self: *const Bitmap) Keys {
        const p: [*]u64 = @ptrCast(self.data.ptr);
        const node_size = keys_mod.nodeSizeOf(p[0]);
        assert(node_size % 4 == 0);
        assert(node_size >= 16 and node_size <= self.data.len);
        return .{ .n = p[0 .. node_size / 4] };
    }

    fn setNodeSize(self: *Bitmap, node_size: usize) void {
        const p: [*]u64 = @ptrCast(self.data.ptr);
        p[0] = keys_mod.packNodeSize(node_size);
    }

    /// Internal: the container living at `offset`, sized by its own header.
    pub fn getContainer(self: *const Bitmap, offset: usize) []u16 {
        assert(offset % 4 == 0);
        const sz = self.data[offset];
        assert(sz >= container.min_size and sz <= container.max_size);
        return self.data[offset..][0..sz];
    }

    /// Copies a borrowed buffer into one this bitmap owns, so that mutations
    /// never write to the caller's buffer. On an owned bitmap this is one
    /// branch. The fallible mutating entry points (`set`, `orInPlace`,
    /// `compact`) call it themselves; the infallible ones (`remove`,
    /// `cleanup`, `andInPlace`, `andNotInPlace`) have no error to report the
    /// copy's allocation failure through, so they assert it has already
    /// happened — call this first to mutate a borrowed bitmap with them.
    pub fn ensureOwned(self: *Bitmap) !void {
        if (self.owned) return;
        const out =
            try self.allocator.alignedAlloc(u16, .@"8", self.data.len);
        @memcpy(out, self.data);
        self.data = out.ptr[0..out.len];
        self.cap = out.len;
        self.owned = true;
    }

    /// The capacity to allocate for a buffer that must hold `needed` u16s.
    /// Lifted from std.array_list.growCapacity, including its 1.5x factor and
    /// its one-cache-line floor.
    ///
    /// The point of growing off the length required rather than the length
    /// already held is that the result always carries slack. Growing off the
    /// capacity does not: a bitmap container landing in a buffer smaller than
    /// itself asks for more than the capacity, and `cap + by_size` is then
    /// exactly the new length, so the very next expansion reallocates again.
    fn growCapacity(needed: usize) usize {
        const floor = @max(1, std.atomic.cache_line / @sizeOf(u16));
        return needed +| (needed / 2 + floor);
    }

    /// Opens a hole of `by_size` u16s at `offset`, growing the buffer to
    /// suit. Container-unaware: the caller fixes up affected offsets via
    /// `Keys.updateOffsets`. Passing `data.len` scoots nothing and so is a
    /// plain append, which is how a new container is added.
    ///
    /// The hole is NOT zeroed. Nothing reads past what the headers say is
    /// live — array slack, spare key pairs and scoot holes are all dead
    /// bytes — so the caller initializes only what it means to use, and a
    /// bitmap container's payload, whose every bit is data, is zeroed by
    /// whoever creates one (`toBitmap`/`toBitmapInto`, or `zero` at the two
    /// sites that build one bit by bit). Serialization is what stale dead
    /// bytes could leak into, and `compact` — the step before storing —
    /// rebuilds into a `zero`ed buffer, which is what makes its output
    /// canonical. See DESIGN.md.
    ///
    /// Modelled on std.array_list.addManyAt, for its two reasons. Growth tries
    /// `remap` first, which for the C allocator reaches `realloc` and lets a
    /// large buffer grow by extending its mapping instead of copying it. And
    /// when that fails, the head and tail are copied straight into their final
    /// positions in the new allocation, so the tail is copied once rather than
    /// copied whole and then scooted.
    fn scootRight(self: *Bitmap, offset: usize, by_size: usize) !void {
        assert(self.owned); // every mutation begins with ensureOwned
        const old_len = self.data.len;
        const to_size = old_len + by_size;
        assert(offset <= old_len);

        if (to_size > self.cap) {
            const new_cap = growCapacity(to_size);
            const grown =
                self.allocator.remap(self.data.ptr[0..self.cap], new_cap);

            stats.bump(&self.counters, .buffer_grows, 1);
            if (grown) |m| {
                self.data = m.ptr[0..to_size];
                self.cap = new_cap;
            } else {
                stats.bump(&self.counters, .buffer_copied_u16, old_len);
                const out =
                    try self.allocator.alignedAlloc(u16, .@"8", new_cap);
                @memcpy(out[0..offset], self.data[0..offset]);
                @memcpy(
                    out[offset + by_size ..][0 .. old_len - offset],
                    self.data[offset..old_len],
                );
                self.allocator.free(self.data.ptr[0..self.cap]);
                self.data = out.ptr[0..to_size];
                self.cap = new_cap;
                return;
            }
        } else {
            self.data = self.data.ptr[0..to_size];
        }

        // Empty range when this was an append, so the append path pays nothing.
        std.mem.copyBackwards(
            u16,
            self.data[offset + by_size .. to_size],
            self.data[offset..old_len],
        );
    }

    /// Appends an empty array container of `sz` u16s and returns its offset.
    /// Only the header is initialized; the payload is dead bytes until the
    /// cardinality says otherwise.
    fn newContainer(self: *Bitmap, sz: u16) !usize {
        assert(sz % 4 == 0);
        const offset = self.data.len;
        assert(offset % 4 == 0);
        try self.scootRight(offset, sz); // offset == data.len: an append
        self.data[offset] = sz;
        const c = self.getContainer(offset);
        container.setType(c, .array);
        container.setCardinality(c, 0);
        return offset;
    }

    /// Abandons the slot at `offset` after its container moved away: mark it
    /// an empty array container — cardinality zero is what `cleanup` reclaims
    /// by — and leave its payload as dead bytes. Runs that cleanup once
    /// dead slots exceed the `max_dead_divisor` bound — after which every
    /// offset the caller holds may have moved.
    fn markDead(self: *Bitmap, offset: usize) void {
        const sz = self.data[offset];
        const c = self.getContainer(offset);
        container.setType(c, .array);
        container.setCardinality(c, 0);
        stats.bump(&self.counters, .abandoned_u16, sz);
        self.dead += sz;
        if (self.dead * max_dead_divisor > self.data.len) self.cleanup();
    }

    /// Doubles the container that `key` maps to at `offset`, or converts it to
    /// a bitmap container once doubling would exceed the array ceiling.
    ///
    /// A container that is last in the buffer grows by plain append. Any other
    /// is moved to the end instead of being grown in place: growing in place
    /// memmoves everything behind the container at every rung of the size
    /// ladder — quadratic over a build — while the move costs one container
    /// and a dead slot that `markDead` bounds. Offsets held by the caller are
    /// invalid afterwards.
    fn expandContainer(self: *Bitmap, key: u64, offset: usize) !void {
        const sz = self.data[offset];
        // Only array containers ever grow; bitmap containers are already
        // maximal.
        assert(sz >= container.min_size and sz <= container.max_array_size);
        const new_sz = container.nextArraySize(sz);
        stats.bump(&self.counters, .container_grows, 1);

        if (offset + sz == self.data.len) {
            // No other container's offset is beyond ours, so no key needs
            // fixing up.
            try self.scootRight(self.data.len, new_sz - sz);
            self.data[offset] = new_sz;
            if (new_sz == container.max_size)
                container.array.toBitmap(self.getContainer(offset));
            return;
        }

        stats.bump(&self.counters, .container_relocs, 1);
        const off = try self.newContainer(new_sz);
        @memcpy(self.data[off..][0..sz], self.data[offset..][0..sz]);
        self.data[off] = new_sz; // the copy brought the old size header along
        const inserted = self.keys().set(key, off, &self.counters);
        assert(!inserted); // the key exists; only its offset moved
        if (new_sz == container.max_size)
            container.array.toBitmap(self.getContainer(off));
        self.markDead(offset);
    }

    /// Registers `offset` for `key`, returning the offset to use afterwards:
    /// growing the keys node shifts every container, including this one.
    fn setKey(self: *Bitmap, key: u64, offset: usize) !usize {
        // Nothing to do when the key is already present.
        if (!self.keys().set(key, offset, &self.counters)) return offset;
        if (!self.keys().isFull()) return offset;

        stats.bump(&self.counters, .node_grows, 1);
        const cur_size = self.keys().n.len * 4; // u64 -> u16
        const by_size = @min(cur_size, max_node_growth);

        try self.scootRight(cur_size, by_size);
        self.setNodeSize(cur_size + by_size);

        // Not updateOffsets: the first container sits exactly at cur_size and
        // did move, so every offset shifts, not just those strictly beyond.
        const ks = self.keys();
        var i: usize = 0;
        while (i < ks.numKeys()) : (i += 1) {
            ks.setValAt(i, ks.val(i) + by_size);
        }
        return offset + by_size;
    }

    /// Closes the hole of `by_size` u16s at `offset` by shifting the tail left.
    /// Container-unaware and never reallocating; the caller fixes up offsets.
    fn scootLeft(self: *Bitmap, offset: usize, by_size: usize) void {
        const old_len = self.data.len;
        assert(offset + by_size <= old_len);
        std.mem.copyForwards(
            u16,
            self.data[offset .. old_len - by_size],
            self.data[offset + by_size .. old_len],
        );
        self.data = self.data.ptr[0 .. old_len - by_size];
    }

    /// Installs the container `src` for `key` at `offset`, growing the
    /// container already there when `src` no longer fits it — up to the full
    /// bitmap size, which also retypes it. Port of sroar's copyAt; it lands
    /// the results that `container.containerOr` had to build in its scratch
    /// buffer.
    ///
    /// Like `expandContainer`, a mid-buffer container that must grow is not
    /// grown in place: `src` replaces its contents entirely anyway, so it is
    /// written to a fresh slot at the end and the old slot abandoned, and the
    /// tail of the buffer never moves. Offsets held by the caller are invalid
    /// afterwards.
    fn copyAt(self: *Bitmap, key: u64, offset: usize, src: []const u16) !void {
        const dst_size = self.data[offset];
        assert(dst_size >= container.min_size);

        // An array result that already fits keeps the larger allocation: the
        // container's own size header must survive the copy.
        if (container.getType(src) == .array and
            dst_size >= container.size(src))
        {
            @memcpy(self.data[offset..][0..src.len], src);
            self.data[offset] = dst_size;
            return;
        }

        const target: u16 = if (container.getType(src) == .bitmap) blk: {
            assert(container.size(src) == container.max_size);
            break :blk container.max_size;
        } else blk: {
            var t = container.nextArraySize(dst_size);
            while (t < container.size(src)) t = container.nextArraySize(t);
            // containerOr only ever builds array results that an array
            // container can hold, so the step never runs past the array
            // ceiling.
            assert(t <= container.max_array_size);
            break :blk t;
        };

        if (offset + dst_size == self.data.len) {
            // Last in the buffer: growing is a plain append.
            try self.scootRight(self.data.len, target - dst_size);
            @memcpy(self.data[offset..][0..src.len], src);
            self.data[offset] = target;
            return;
        }

        const off = try self.newContainer(target);
        @memcpy(self.data[off..][0..src.len], src);
        self.data[off] = target;
        const inserted = self.keys().set(key, off, &self.counters);
        assert(!inserted); // the key exists; only its offset moved
        self.markDead(offset);
    }

    /// Makes room for `n` further keys in one step, so that a bulk builder can
    /// create every key before any container and never move the containers
    /// again. Port of sroar's initSpaceForKeys.
    fn initSpaceForKeys(self: *Bitmap, n: usize) !void {
        if (n == 0) return;
        const cur_size = self.keys().size();
        const by_size = n * key_pair_size;

        try self.scootRight(cur_size, by_size);
        self.setNodeSize(cur_size + by_size);

        // Every container sat beyond the node, so every offset shifts.
        const ks = self.keys();
        var i: usize = 0;
        while (i < ks.numKeys()) : (i += 1) ks.setValAt(i, ks.val(i) + by_size);
    }

    /// Reserves a container of at least `sz` u16s for `key` and returns its
    /// offset. The container is empty; the caller fills in its type, values and
    /// cardinality but must leave the size header alone, since a reused
    /// container can be larger than requested.
    ///
    /// Key 0's container exists from init, so a bulk builder reuses it instead
    /// of leaving it behind as dead space.
    fn addContainer(self: *Bitmap, key: u64, sz: u16) !usize {
        if (key == 0 and sz < container.max_size) {
            const offset = self.keys().val(0);
            const c = self.getContainer(offset);
            if (container.getType(c) == .array and
                container.getCardinality(c) == 0 and
                container.size(c) >= sz) return offset;
        }
        const offset = try self.newContainer(sz);
        return try self.setKey(key, offset);
    }

    // -----------------------------------------------------------------------
    // Point operations
    // -----------------------------------------------------------------------

    /// The container offset for `key`, or null when `key` has no container.
    ///
    /// Repeats of one key and runs of ascending keys — sequential row-ids —
    /// are answered by `Keys.getValue`'s neighbourhood hint in a compare or
    /// two rather than a search; see keys.zig. (An earlier one-entry cursor
    /// field did the same for repeats only, and had to be nulled wherever
    /// containers moved. The hint carries a keys-node index, which nothing
    /// moves, and is checked against the node before use.)
    fn getOffset(self: *Bitmap, key: u64) ?usize {
        return self.keys().getValue(key);
    }

    /// `getOffset`, creating a minimum-size container for `key` when it has
    /// none.
    fn getOrCreateOffset(self: *Bitmap, key: u64) !usize {
        if (self.getOffset(key)) |off| return off;
        const fresh = try self.newContainer(container.min_size);
        return self.setKey(key, fresh);
    }

    /// Adds x. Returns true if it was not already present. On a bitmap
    /// opened with `fromBuffer`, the first mutation copies the buffer out;
    /// see `ensureOwned`.
    pub fn set(self: *Bitmap, x: u64) !bool {
        try self.ensureOwned();
        stats.bump(&self.counters, .sets, 1);
        const key = x & key_mask;
        const lo: u16 = @truncate(x);
        const offset = try self.getOrCreateOffset(key);

        const c = self.getContainer(offset);
        switch (container.getType(c)) {
            .array => {
                if (!container.array.add(c, lo, &self.counters)) return false;
                // Restore the free-slot invariant before anyone reads the
                // container.
                if (container.array.isFull(c))
                    try self.expandContainer(key, offset);
                return true;
            },
            .bitmap => return container.bitmap.add(c, lo),
        }
    }

    /// Reports whether x is present.
    pub fn contains(self: *const Bitmap, x: u64) bool {
        const offset = self.keys().getValue(x & key_mask) orelse return false;
        return container.has(self.getContainer(offset), @truncate(x));
    }

    /// Removes x. Returns true if it was present. Never shrinks the buffer.
    /// Asserts an owned buffer: to remove from a bitmap opened with
    /// `fromBuffer`, call `ensureOwned` first.
    pub fn remove(self: *Bitmap, x: u64) bool {
        assert(self.owned); // infallible: see ensureOwned
        const offset = self.getOffset(x & key_mask) orelse return false;
        return container.remove(self.getContainer(offset), @truncate(x));
    }

    // -----------------------------------------------------------------------
    // Queries
    // -----------------------------------------------------------------------

    /// Number of values in the bitmap.
    pub fn getCardinality(self: *const Bitmap) u64 {
        const ks = self.keys();
        var total: u64 = 0;
        var i: usize = 0;
        while (i < ks.numKeys()) : (i += 1) {
            total += container.getCardinality(self.getContainer(ks.val(i)));
        }
        return total;
    }

    /// True when the bitmap holds no values. Cheaper than
    /// getCardinality() == 0.
    pub fn isEmpty(self: *const Bitmap) bool {
        const ks = self.keys();
        var i: usize = 0;
        while (i < ks.numKeys()) : (i += 1) {
            const c = self.getContainer(ks.val(i));
            if (container.getCardinality(c) > 0) return false;
        }
        return true;
    }

    /// Smallest value, or null if the bitmap is empty.
    pub fn minimum(self: *const Bitmap) ?u64 {
        const ks = self.keys();
        var i: usize = 0;
        while (i < ks.numKeys()) : (i += 1) {
            const c = self.getContainer(ks.val(i));
            // Emptied containers are kept in place until cleanup, so skip them.
            if (container.getCardinality(c) == 0) continue;
            return ks.key(i) | container.minimum(c);
        }
        return null;
    }

    /// Largest value, or null if the bitmap is empty.
    pub fn maximum(self: *const Bitmap) ?u64 {
        const ks = self.keys();
        var i = ks.numKeys();
        while (i > 0) {
            i -= 1;
            const c = self.getContainer(ks.val(i));
            if (container.getCardinality(c) == 0) continue;
            return ks.key(i) | container.maximum(c);
        }
        return null;
    }

    /// Returns every value in ascending order. The caller owns the slice.
    pub fn toArray(self: *const Bitmap, allocator: std.mem.Allocator) ![]u64 {
        const out = try allocator.alloc(u64, @intCast(self.getCardinality()));
        errdefer allocator.free(out);
        self.toArrayInto(out);
        return out;
    }

    /// Writes every value into `out`, which must be exactly `getCardinality()`
    /// long. For a caller that materializes repeatedly, this avoids the
    /// allocation `toArray` makes, and the buffer can be reused.
    ///
    /// Deliberately not a drain of `iterator()`. The iterator has to be able to
    /// stop after any single value, so it re-derives the keys view, re-reads
    /// the key and offset, re-slices the container and re-dispatches on its
    /// type for *every* value it returns. Hoisting that out of the inner loop
    /// leaves an array container as a widening copy and a bitmap container as a
    /// `@ctz` walk, which is where the time goes.
    pub fn toArrayInto(self: *const Bitmap, out: []u64) void {
        const ks = self.keys();
        const num_keys = ks.numKeys();
        var i: usize = 0;
        var ki: usize = 0;
        while (ki < num_keys) : (ki += 1) {
            const key = ks.key(ki);
            const c = self.getContainer(ks.val(ki));
            switch (container.getType(c)) {
                .array => {
                    // Widened explicitly rather than left to the optimizer.
                    // The scalar form compiles to a scalar unrolled loop: LLVM
                    // cannot rule out `out` overlapping the container it is
                    // reading, and Zig has no equivalent of the C strict
                    // aliasing rule that lets CRoaring vectorize the same loop.
                    // Spelling it out costs a few lines and roughly halves the
                    // time, and array containers hold most of the values in
                    // sparse data.
                    const vals = container.array.values(c);
                    const lanes = 8;
                    const V16 = @Vector(lanes, u16);
                    const V64 = @Vector(lanes, u64);
                    const key_vec: V64 = @splat(key);
                    var j: usize = 0;
                    while (j + lanes <= vals.len) : (j += lanes) {
                        const v: V16 = vals[j..][0..lanes].*;
                        out[i..][0..lanes].* = @as(V64, v) | key_vec;
                        i += lanes;
                    }
                    while (j < vals.len) : (j += 1) {
                        out[i] = key | @as(u64, vals[j]);
                        i += 1;
                    }
                },
                .bitmap => {
                    for (container.bitmap.constWords(c), 0..) |word, wi| {
                        var w = word;
                        const base = key | @as(u64, wi) * 64;
                        while (w != 0) {
                            out[i] = base | @ctz(w);
                            i += 1;
                            w &= w - 1; // clear the lowest set bit
                        }
                    }
                },
            }
        }
        assert(i == out.len);
    }

    /// A forward iterator. Valid only until the bitmap is mutated.
    pub fn iterator(self: *const Bitmap) Iterator {
        return Iterator.init(self);
    }

    // -----------------------------------------------------------------------
    // Serialization
    // -----------------------------------------------------------------------

    /// The bitmap's buffer, borrowed. O(1). Invalidated by any growth or
    /// deinit.
    pub fn toBuffer(self: *const Bitmap) AlignedConstU8 {
        const p: [*]align(8) const u8 = @ptrCast(self.data.ptr);
        return p[0 .. self.data.len * 2];
    }

    /// An owning copy of the bitmap's buffer.
    pub fn toBufferCopy(
        self: *const Bitmap,
        allocator: std.mem.Allocator,
    ) !AlignedU8 {
        const src = self.toBuffer();
        const out = try allocator.alignedAlloc(u8, .@"8", src.len);
        @memcpy(out, src);
        return out;
    }

    /// Wraps `buf` in O(1) without copying or validating it. The bitmap may
    /// be mutated: the first mutation copies the buffer out (`ensureOwned`),
    /// so `buf` itself is never written to. Reads are free of any copy. `buf`
    /// must outlive the bitmap. Returns a fresh empty bitmap if `buf` is too
    /// small or oddly sized to be a bitmap at all.
    pub fn fromBuffer(allocator: std.mem.Allocator, buf: AlignedU8) !Bitmap {
        if (buf.len % 2 != 0 or buf.len < min_buffer_bytes)
            return init(allocator);

        // A version this build does not know means the layout may differ;
        // misreading it silently would be far worse than refusing. (Unlike
        // the size checks above, which mean "not a bitmap at all" and get an
        // empty one, this is a bitmap — just not ours to read.)
        const words: [*]const u64 = @ptrCast(@alignCast(buf.ptr));
        if (keys_mod.versionOf(words[0]) != format_version)
            return error.UnsupportedFormatVersion;

        const p: [*]align(8) u16 = @ptrCast(buf.ptr);
        return .{
            .data = p[0 .. buf.len / 2],
            .cap = buf.len / 2,
            .owned = false,
            .allocator = allocator,
        };
    }

    /// Copies `buf` into a freshly owned bitmap. Also the path for input that
    /// is not 8-byte aligned.
    pub fn fromBufferCopy(
        allocator: std.mem.Allocator,
        buf: []const u8,
    ) !Bitmap {
        if (buf.len % 2 != 0 or buf.len < min_buffer_bytes)
            return init(allocator);

        const out = try allocator.alignedAlloc(u8, .@"8", buf.len);
        errdefer allocator.free(out);
        @memcpy(out, buf);

        var bm = try fromBuffer(allocator, out);
        bm.owned = true; // we allocated `out`, so the bitmap must free it
        return bm;
    }

    /// An independent, owned copy of this bitmap.
    pub fn clone(self: *const Bitmap) !Bitmap {
        const buf = try self.toBufferCopy(self.allocator);
        errdefer self.allocator.free(buf);
        var bm = try fromBuffer(self.allocator, buf);
        bm.owned = true; // we allocated buf, so the clone must free it
        return bm;
    }

    // -----------------------------------------------------------------------
    // Set operations
    // -----------------------------------------------------------------------

    /// self := self ∩ other. In place, allocation-free and never failing: an
    /// intersection is a subset of self, so every container shrinks where it
    /// stands and containers whose key is absent from `other` are emptied
    /// rather than removed.
    ///
    /// Does NOT call `cleanup`: the emptied containers keep their space until
    /// the caller asks for it back, so a chain of intersections compacts once
    /// at the end instead of after every step.
    pub fn andInPlace(self: *Bitmap, other: *const Bitmap) void {
        assert(self.owned); // infallible: see ensureOwned
        // Nothing here grows the buffer, so both key views stay valid.
        const ka = self.keys();
        const kb = other.keys();
        var ai: usize = 0;
        var bi: usize = 0;
        while (ai < ka.numKeys() and bi < kb.numKeys()) {
            const ak = ka.key(ai);
            const bk = kb.key(bi);
            if (ak == bk) {
                container.containerAnd(
                    self.getContainer(ka.val(ai)),
                    other.getContainer(kb.val(bi)),
                );
                ai += 1;
                bi += 1;
            } else if (ak < bk) {
                container.zeroOut(self.getContainer(ka.val(ai)));
                ai += 1;
            } else {
                bi += 1;
            }
        }
        // Keys past the end of `other` have nothing to intersect with.
        while (ai < ka.numKeys()) : (ai += 1) {
            container.zeroOut(self.getContainer(ka.val(ai)));
        }
    }

    /// self := self \ other. In place, allocation-free and never failing; a
    /// difference is a subset of self. Keys absent from `other` are untouched.
    /// Like `andInPlace`, it leaves emptied containers for `cleanup`.
    pub fn andNotInPlace(self: *Bitmap, other: *const Bitmap) void {
        assert(self.owned); // infallible: see ensureOwned
        const ka = self.keys();
        const kb = other.keys();
        var ai: usize = 0;
        var bi: usize = 0;
        while (ai < ka.numKeys() and bi < kb.numKeys()) {
            const ak = ka.key(ai);
            const bk = kb.key(bi);
            if (ak == bk) {
                container.containerAndNot(
                    self.getContainer(ka.val(ai)),
                    other.getContainer(kb.val(bi)),
                );
                ai += 1;
                bi += 1;
            } else if (ak < bk) {
                ai += 1;
            } else {
                bi += 1;
            }
        }
    }

    /// self := self ∪ other. Allocates: containers grow, new ones are copied
    /// over from `other`, and one scratch container is used for array merges.
    /// `other` must not alias self.
    ///
    /// Every key of `other` that self does not already have is inserted one at
    /// a time, and each insertion memmoves the tail of the keys node —
    /// O(numKeys) per new key, so O(n²) when the operands share few keys. That
    /// is the price of unioning *into* an existing bitmap. A caller that only
    /// wants the union as a new bitmap should use `Or` or `fastOr`, which size
    /// the keys node for the whole result before creating any of it.
    pub fn orInPlace(self: *Bitmap, other: *const Bitmap) !void {
        try self.ensureOwned();
        const buf = try self.allocator.alignedAlloc(
            u16,
            .@"8",
            container.max_size,
        );
        defer self.allocator.free(buf);
        try self.orWith(other, buf, false);
    }

    /// The body shared by orInPlace, Or and fastOr. `buf` is one scratch
    /// container for the merges that cannot run in place. In `lazy` mode
    /// bitmap containers are left with an invalid cardinality, which the
    /// caller must repair before the bitmap is handed out.
    fn orWith(
        self: *Bitmap,
        other: *const Bitmap,
        buf: AlignedU16,
        lazy: bool,
    ) !void {
        // Growing self would reallocate other's buffer as well if they aliased,
        // leaving the container we are copying from dangling.
        assert(self != other);

        var si: usize = 0;
        while (si < other.keys().numKeys()) : (si += 1) {
            const kb = other.keys();
            const src = other.getContainer(kb.val(si));
            if (container.getCardinality(src) == 0) continue;
            const key = kb.key(si);

            const ks = self.keys();
            const idx = ks.search(key);
            if (idx >= ks.numKeys() or ks.key(idx) != key) {
                // The key is new here, so take a copy of the whole container.
                const offset = try self.addContainer(key, container.size(src));
                try self.copyAt(key, offset, src);
                continue;
            }
            const offset = ks.val(idx);
            const dst = self.getContainer(offset);
            if (container.containerOr(dst, src, buf, lazy)) |c| {
                // The union outgrew the container; install what was built
                // in buf.
                try self.copyAt(key, offset, c);
            }
        }
    }

    /// a ∩ b as a new bitmap owned by the caller.
    ///
    /// The cost is proportional to the *output*: a key that intersects to
    /// nothing costs one merge step and no space at all, and every container is
    /// created at the size its own result needs. So there is nothing to compact
    /// afterwards — unlike sroar, which copies a's containers in whole only
    /// to shrink them again and then sweeps the empties away.
    pub fn And(
        allocator: std.mem.Allocator,
        a: *const Bitmap,
        b: *const Bitmap,
    ) !Bitmap {
        var res = try init(allocator);
        errdefer res.deinit();
        // Room for every shared key up front: the keys below then go into a
        // node that never grows, so no container ever has to move.
        try res.initSpaceForKeys(countSharedKeys(a, b));

        // One scratch container per call. The intersection cannot be computed
        // in place, since neither operand may be touched, and its size is not
        // known until it has been computed.
        var scratch: [container.max_size]u16 align(8) = undefined;

        const ka = a.keys();
        const kb = b.keys();
        var ai: usize = 0;
        var bi: usize = 0;
        while (ai < ka.numKeys() and bi < kb.numKeys()) {
            const ak = ka.key(ai);
            const bk = kb.key(bi); // kb, not ka: bi indexes b's keys
            if (ak < bk) {
                ai += 1;
                continue;
            }
            if (ak > bk) {
                bi += 1;
                continue;
            }
            const built = container.containerAndInto(
                &scratch,
                a.getContainer(ka.val(ai)),
                b.getContainer(kb.val(bi)),
            );
            // An empty intersection gets neither a container nor a key.
            if (container.getCardinality(built) > 0)
                try res.appendResult(ak, built);
            ai += 1;
            bi += 1;
        }
        return res;
    }

    // -----------------------------------------------------------------------
    // Fused cardinalities
    //
    // "How big would this operation's result be?" answered without producing
    // the result: one merge walk over the two key lists, and for the keys they
    // share `container.containerAndCardinality`, which counts an overlap in
    // place. No allocation, so none of the three can fail, and no bitmap is
    // built and thrown away. CRoaring offers the same three as
    // roaring64_bitmap_{and,or,andnot}_cardinality.
    // -----------------------------------------------------------------------

    /// |self ∩ other|. Keys held by only one side intersect to nothing, so
    /// only the shared ones cost anything at all.
    pub fn andCardinality(self: *const Bitmap, other: *const Bitmap) u64 {
        const ka = self.keys();
        const kb = other.keys();
        var total: u64 = 0;
        var ai: usize = 0;
        var bi: usize = 0;
        while (ai < ka.numKeys() and bi < kb.numKeys()) {
            const ak = ka.key(ai);
            const bk = kb.key(bi);
            if (ak < bk) {
                ai += 1;
            } else if (ak > bk) {
                bi += 1;
            } else {
                total += container.containerAndCardinality(
                    self.getContainer(ka.val(ai)),
                    other.getContainer(kb.val(bi)),
                );
                ai += 1;
                bi += 1;
            }
        }
        return total;
    }

    /// |self ∪ other|. A key only one side has contributes its container's
    /// cardinality straight from the header; a shared key contributes
    /// |a| + |b| - |a ∩ b|, so only the overlap has to be counted.
    pub fn orCardinality(self: *const Bitmap, other: *const Bitmap) u64 {
        const ka = self.keys();
        const kb = other.keys();
        var total: u64 = 0;
        var ai: usize = 0;
        var bi: usize = 0;
        while (ai < ka.numKeys() and bi < kb.numKeys()) {
            const ak = ka.key(ai);
            const bk = kb.key(bi);
            if (ak < bk) {
                total +=
                    container.getCardinality(self.getContainer(ka.val(ai)));
                ai += 1;
            } else if (ak > bk) {
                total +=
                    container.getCardinality(other.getContainer(kb.val(bi)));
                bi += 1;
            } else {
                const ca = self.getContainer(ka.val(ai));
                const cb = other.getContainer(kb.val(bi));
                total += container.getCardinality(ca) +
                    container.getCardinality(cb) -
                    container.containerAndCardinality(ca, cb);
                ai += 1;
                bi += 1;
            }
        }
        // Whatever is left on either side belongs to the union whole.
        while (ai < ka.numKeys()) : (ai += 1) {
            total += container.getCardinality(self.getContainer(ka.val(ai)));
        }
        while (bi < kb.numKeys()) : (bi += 1) {
            total += container.getCardinality(other.getContainer(kb.val(bi)));
        }
        return total;
    }

    /// |self \ other|. A key `other` does not have survives whole; a shared key
    /// keeps |a| - |a ∩ b|; a key only `other` has removes nothing.
    pub fn andNotCardinality(self: *const Bitmap, other: *const Bitmap) u64 {
        const ka = self.keys();
        const kb = other.keys();
        var total: u64 = 0;
        var ai: usize = 0;
        var bi: usize = 0;
        while (ai < ka.numKeys() and bi < kb.numKeys()) {
            const ak = ka.key(ai);
            const bk = kb.key(bi);
            if (ak < bk) {
                total +=
                    container.getCardinality(self.getContainer(ka.val(ai)));
                ai += 1;
            } else if (ak > bk) {
                bi += 1;
            } else {
                const ca = self.getContainer(ka.val(ai));
                const cb = other.getContainer(kb.val(bi));
                total += container.getCardinality(ca) -
                    container.containerAndCardinality(ca, cb);
                ai += 1;
                bi += 1;
            }
        }
        // Keys past the end of `other` have nothing subtracted from them.
        while (ai < ka.numKeys()) : (ai += 1) {
            total += container.getCardinality(self.getContainer(ka.val(ai)));
        }
        return total;
    }

    /// How many keys `a` and `b` have in common: one merge walk over the two
    /// sorted key lists, reading no containers.
    fn countSharedKeys(a: *const Bitmap, b: *const Bitmap) usize {
        const ka = a.keys();
        const kb = b.keys();
        var n: usize = 0;
        var ai: usize = 0;
        var bi: usize = 0;
        while (ai < ka.numKeys() and bi < kb.numKeys()) {
            const ak = ka.key(ai);
            const bk = kb.key(bi);
            if (ak < bk) {
                ai += 1;
            } else if (ak > bk) {
                bi += 1;
            } else {
                n += 1;
                ai += 1;
                bi += 1;
            }
        }
        return n;
    }

    /// Installs the finished, non-empty container `built` under `key`, at the
    /// smallest size that holds it. Called with ascending keys and a node
    /// already sized for all of them, so the key insert moves nothing and the
    /// container lands at the end of the buffer.
    ///
    /// A bitmap-shaped result small enough for an array container is written
    /// out as an array container. That picks the shape of a container as it is
    /// created; it is not the bitmap -> array demotion of an existing container
    /// that DESIGN.md rules out, since nothing here is converted.
    fn appendResult(self: *Bitmap, key: u64, built: []const u16) !void {
        const card = container.getCardinality(built);
        assert(card > 0);
        const sz = container.arraySizeFor(card) orelse container.max_size;

        // Key 0's container exists from init, so resize that one rather than
        // appending a second and orphaning the first. Key 0 is in every bitmap,
        // hence always the first key handled and still last in the buffer.
        const offset = if (key == 0) blk: {
            const off = self.keys().val(0);
            try self.growContainerTo(off, sz);
            break :blk off;
        } else try self.setKey(key, try self.newContainer(sz));

        const dst = self.getContainer(offset);
        switch (container.getType(built)) {
            .array => {
                @memcpy(
                    dst[container.start_idx..][0..card],
                    container.array.values(built),
                );
                container.setCardinality(dst, card);
            },
            .bitmap => if (sz == container.max_size)
                @memcpy(dst, built) // both are full bitmap containers
            else
                container.bitmap.toArrayInto(dst, built),
        }
    }

    /// Grows the container at `offset` to exactly `sz` u16s; the extra room
    /// is dead bytes. `sz` must not be smaller than the container's current
    /// size.
    fn growContainerTo(self: *Bitmap, offset: usize, sz: u16) !void {
        const cur = self.data[offset];
        if (cur >= sz) return;
        try self.scootRight(offset + cur, sz - cur);
        self.keys().updateOffsets(offset, sz - cur, true);
        self.data[offset] = sz;
    }

    /// a ∪ b as a new bitmap owned by the caller.
    ///
    /// One merge walk over the two key lists, the shape of `And`. The keys
    /// node is sized for every key of either operand up front, so no key
    /// insertion ever moves a container (the quadratic term `orInPlace` pays
    /// on key-disjoint operands). A container only one side has is copied
    /// straight in; a shared key's containers are unioned into one scratch
    /// container and appended at the size the result actually needs, as an
    /// array whenever it fits one — so, unlike a `fastOr` result, nothing here
    /// is sized for the sum of its inputs and there is no dead space to
    /// `cleanup` afterwards.
    ///
    /// This is not `fastOr` of two inputs, though it was once: that pre-sizes
    /// and lazily unions in two passes through a scratch buffer, which pays
    /// off across many inputs and merely costs three passes over the output
    /// for two.
    pub fn Or(
        allocator: std.mem.Allocator,
        a: *const Bitmap,
        b: *const Bitmap,
    ) !Bitmap {
        var res = try init(allocator);
        errdefer res.deinit();
        const ka = a.keys();
        const kb = b.keys();
        // Room for every key of either operand: the keys go into a node that
        // never grows, so no container ever has to move.
        try res.initSpaceForKeys(
            ka.numKeys() + kb.numKeys() - countSharedKeys(a, b),
        );

        // One scratch container per call; a shared key's union cannot be
        // computed in place, since neither operand may be touched.
        var scratch: [container.max_size]u16 align(8) = undefined;

        var ai: usize = 0;
        var bi: usize = 0;
        while (ai < ka.numKeys() or bi < kb.numKeys()) {
            const a_left = ai < ka.numKeys();
            const b_left = bi < kb.numKeys();
            if (a_left and (!b_left or ka.key(ai) < kb.key(bi))) {
                const c = a.getContainer(ka.val(ai));
                if (container.getCardinality(c) > 0)
                    try res.appendResult(ka.key(ai), c);
                ai += 1;
            } else if (b_left and (!a_left or kb.key(bi) < ka.key(ai))) {
                const c = b.getContainer(kb.val(bi));
                if (container.getCardinality(c) > 0)
                    try res.appendResult(kb.key(bi), c);
                bi += 1;
            } else {
                const built = container.containerOrInto(
                    &scratch,
                    a.getContainer(ka.val(ai)),
                    b.getContainer(kb.val(bi)),
                );
                // Two emptied containers union to nothing: no key for that.
                if (container.getCardinality(built) > 0)
                    try res.appendResult(ka.key(ai), built);
                ai += 1;
                bi += 1;
            }
        }
        return res;
    }

    /// The union of many bitmaps as a new bitmap owned by the caller. Faster
    /// than folding `orInPlace`: the keys and the containers of the result are
    /// sized up front from the summed cardinalities, so no key insertion has to
    /// move the containers, and each container's cardinality is counted once at
    /// the end rather than after every input.
    pub fn fastOr(
        allocator: std.mem.Allocator,
        bitmaps: []const *const Bitmap,
    ) !Bitmap {
        if (bitmaps.len == 0) return init(allocator);
        // sroar hands back the input itself here; the result must be the
        // caller's to own and to keep mutating, so copy it.
        if (bitmaps.len == 1)
            return fromBufferCopy(allocator, bitmaps[0].toBuffer());

        // Every (key, cardinality) pair of every input, sorted by key and
        // then merged. sroar uses a map here; one sort is simpler and
        // allocates once.
        var total: usize = 0;
        for (bitmaps) |bm| total += bm.keys().numKeys();

        const scratch = try allocator.alloc(KeyEstimate, total);
        defer allocator.free(scratch);

        var n: usize = 0;
        for (bitmaps) |bm| {
            const ks = bm.keys();
            var i: usize = 0;
            while (i < ks.numKeys()) : (i += 1) {
                const c = bm.getContainer(ks.val(i));
                scratch[n] = .{
                    .key = ks.key(i),
                    .card = container.getCardinality(c),
                };
                n += 1;
            }
        }
        std.sort.pdq(KeyEstimate, scratch, {}, KeyEstimate.lessThan);
        const est = mergeEstimates(scratch);

        var dst = try init(allocator);
        errdefer dst.deinit();

        // All the keys first: inserting one later would move every container.
        try dst.initSpaceForKeys(est.len);
        for (est) |e| {
            if (e.key == 0) continue; // key 0 exists, with a container already
            _ = try dst.setKey(e.key, 0);
        }

        // Bitmap containers first, array containers after them: an array
        // container that has to grow then only moves the arrays behind it.
        for ([2]bool{ true, false }) |bitmap_pass| {
            for (est) |e| {
                const sz = containerSizeFor(e.card);
                if ((sz == container.max_size) != bitmap_pass) continue;
                const offset = try dst.addContainer(e.key, sz);
                if (bitmap_pass) {
                    const c = dst.getContainer(offset);
                    container.setType(c, .bitmap);
                    // The lazy unions below OR into this payload, so every
                    // bit of it is data and must start cleared.
                    zero(container.bitmap.words(c));
                }
            }
        }

        const buf = try allocator.alignedAlloc(u16, .@"8", container.max_size);
        defer allocator.free(buf);
        for (bitmaps) |bm| try dst.orWith(bm, buf, true);

        // Repair the cardinalities the lazy unions left invalid.
        const ks = dst.keys();
        var i: usize = 0;
        while (i < ks.numKeys()) : (i += 1) {
            const c = dst.getContainer(ks.val(i));
            if (container.getCardinality(c) == container.invalid_cardinality) {
                container.recomputeCardinality(c);
            }
        }
        return dst;
    }

    /// Builds a bitmap from values in ascending order; duplicates are ignored.
    /// Much cheaper than repeated `set`: the keys node is sized in one step and
    /// every container is written once, at its final size.
    pub fn fromSortedList(
        allocator: std.mem.Allocator,
        vals: []const u64,
    ) !Bitmap {
        var bm = try init(allocator);
        errdefer bm.deinit();
        if (vals.len == 0) return bm;

        // Count the distinct keys other than 0, which always exists already.
        var num_keys: usize = 0;
        var last_key: u64 = 0;
        for (vals) |x| {
            const key = x & key_mask;
            if (key != 0 and key != last_key) num_keys += 1;
            last_key = key;
        }
        try bm.initSpaceForKeys(num_keys);

        var i: usize = 0;
        while (i < vals.len) {
            const key = vals[i] & key_mask;
            var j = i;
            var distinct: usize = 0;
            while (j < vals.len and (vals[j] & key_mask) == key) : (j += 1) {
                // the input must be sorted
                assert(j == 0 or vals[j] >= vals[j - 1]);
                if (j == i or vals[j] != vals[j - 1]) distinct += 1;
            }
            try bm.fillContainer(key, vals[i..j], distinct);
            i = j;
        }
        return bm;
    }

    /// Writes one run of `vals` — all sharing `key`, ascending, `distinct` of
    /// them unique — into a single container sized for exactly that run.
    fn fillContainer(
        self: *Bitmap,
        key: u64,
        vals: []const u64,
        distinct: usize,
    ) !void {
        const sz = containerSizeFor(distinct);
        const offset = try self.addContainer(key, sz);
        const c = self.getContainer(offset);

        if (sz == container.max_size) {
            container.setType(c, .bitmap);
            const w = container.bitmap.words(c);
            zero(w); // every bit of a bitmap payload is data
            for (vals) |x| {
                const lo: u16 = @truncate(x);
                w[lo >> 6] |= @as(u64, 1) << @truncate(lo);
            }
        } else {
            var n: usize = 0;
            for (vals, 0..) |x, k| {
                if (k > 0 and vals[k] == vals[k - 1]) continue;
                c[container.start_idx + n] = @truncate(x);
                n += 1;
            }
            assert(n == distinct);
        }
        container.setCardinality(c, @intCast(distinct));
    }

    /// Reclaims the space of every container left empty by andInPlace,
    /// andNotInPlace or remove, together with its key, and of every dead slot
    /// abandoned by container relocation. Key 0 always survives.
    ///
    /// Allocation-free: sroar collects the removed ranges into slices and sorts
    /// them; walking the buffer left to right instead needs no bookkeeping and
    /// merges neighbouring holes just as well.
    pub fn cleanup(self: *Bitmap) void {
        assert(self.owned); // infallible: see ensureOwned
        // Keys first: while they still point at their own containers, an empty
        // container can be told apart from a live one by its cardinality alone.
        stats.bump(&self.counters, .cleanups, 1);
        self.cleanupKeys();
        self.cleanupContainers();
        self.dead = 0;
    }

    /// The smallest size a container holding `card` values may legally have,
    /// and hence what `compact` gives it. Bitmap containers that fit an array
    /// become one: a bitmap container costs a fixed `max_size` however few of
    /// its bits are set.
    fn compactSizeFor(card: usize) u16 {
        return container.compactArraySizeFor(card) orelse container.max_size;
    }

    /// Rewrites the bitmap into the smallest buffer that holds it, for storing.
    ///
    /// Three kinds of slack go away:
    ///
    ///   - dead space left behind by container relocation, via `cleanup`
    ///   - the gap between a container's cardinality and its ladder step, since
    ///     `container.array_sizes` rounds up so containers have room to grow
    ///   - bitmap containers holding few enough values to fit an array, which
    ///     is a fixed `max_size` no matter how sparse it is
    ///
    /// The result is an ordinary mutable bitmap, not a frozen one: every array
    /// container keeps the free slot its invariant demands and the keys node
    /// keeps one spare key, so the next `set` behaves exactly as it would have.
    /// It is only sized so that growth starts sooner. Serializing right after
    /// compacting is the point — `toBuffer` then hands back the smallest
    /// buffer that round-trips.
    ///
    /// O(total values): every container is rewritten, and a bitmap container
    /// that converts is walked bit by bit.
    pub fn compact(self: *Bitmap) !void {
        try self.ensureOwned();
        // Empty containers and dead slots first; no point measuring them.
        self.cleanup();

        const ks = self.keys();
        const num_keys = ks.numKeys();

        // One spare key slot, mirroring the arrays' free slot: `Keys.set`
        // requires the node not be full when it is called.
        const node_size = 4 * (2 * (num_keys + 1) + 2);

        var total: usize = node_size;
        for (0..num_keys) |i| {
            const c = self.getContainer(ks.val(i));
            total += compactSizeFor(container.getCardinality(c));
        }

        const out = try self.allocator.alignedAlloc(u16, .@"8", total);
        errdefer self.allocator.free(out);
        zero(out);

        const p: [*]u64 = @ptrCast(out.ptr);
        const new_ks = Keys{ .n = p[0 .. node_size / 4] };
        new_ks.setNodeSize(node_size);
        new_ks.setNumKeys(num_keys);

        var off: usize = node_size;
        for (0..num_keys) |i| {
            const src = self.getContainer(ks.val(i));
            const card = container.getCardinality(src);
            const sz = compactSizeFor(card);
            const dst = out[off..][0..sz];

            if (sz == container.max_size) {
                // Too dense for an array; carry the bitmap over as it is.
                assert(container.getType(src) == .bitmap);
                @memcpy(dst, src);
            } else switch (container.getType(src)) {
                .array => {
                    container.setType(dst, .array);
                    container.setCardinality(dst, card);
                    @memcpy(
                        dst[container.start_idx..][0..card],
                        container.array.values(src),
                    );
                },
                // Sets type and cardinality itself.
                .bitmap => container.bitmap.toArrayInto(dst, src),
            }
            dst[container.index_size] = sz;

            new_ks.setKeyAt(i, ks.key(i));
            new_ks.setValAt(i, off);
            off += sz;
        }
        assert(off == total);

        if (self.owned) self.allocator.free(self.data.ptr[0..self.cap]);
        self.data = out.ptr[0..total];
        self.cap = total;
        self.owned = true;
        self.dead = 0;
    }

    /// Drops the keys of empty containers, shrinking the node by exactly the
    /// pairs removed. That keeps the node's spare capacity, and with it the
    /// invariant that the node is never observed full.
    fn cleanupKeys(self: *Bitmap) void {
        const ks = self.keys();
        var w: usize = 1; // key 0 stays, empty or not
        var i: usize = 1;
        while (i < ks.numKeys()) : (i += 1) {
            const off = ks.val(i);
            if (container.getCardinality(self.getContainer(off)) == 0) continue;
            ks.setKeyAt(w, ks.key(i));
            ks.setValAt(w, off);
            w += 1;
        }
        const removed = ks.numKeys() - w;
        if (removed == 0) return;

        const by_size = removed * key_pair_size;
        const new_size = ks.size() - by_size;
        ks.setNumKeys(w);
        // The pair slots between w and the shrunk end are spare capacity now
        // (dead bytes); drop the tail of the node the pairs no longer need.
        self.setNodeSize(new_size);
        self.scootLeft(new_size, by_size);

        // Every container sat beyond the node, so every offset moved.
        const shrunk = self.keys();
        var k: usize = 0;
        while (k < shrunk.numKeys()) : (k += 1) {
            shrunk.setValAt(k, shrunk.val(k) - by_size);
        }
    }

    /// Removes every empty container no key points at any more, merging
    /// neighbours into a single move.
    fn cleanupContainers(self: *Bitmap) void {
        var off = self.keys().size();
        while (off < self.data.len) {
            if (!self.isDeadContainer(off)) {
                off += self.data[off];
                continue;
            }
            var run: usize = self.data[off];
            while (off + run < self.data.len and
                self.isDeadContainer(off + run))
            {
                run += self.data[off + run];
            }
            const c = &self.counters;
            stats.bump(c, .cleanup_moved_u16, self.data.len - (off + run));
            stats.bump(c, .cleanup_key_visits, self.keys().numKeys());
            self.scootLeft(off, run);
            self.keys().updateOffsets(off + run - 1, run, false);
            // `off` now holds the container that followed the hole.
        }
    }

    fn isDeadContainer(self: *const Bitmap, off: usize) bool {
        // Key 0's container is kept even when empty: the key must not go, and
        // a key without a container is not representable.
        if (off == self.keys().val(0)) return false;
        return container.getCardinality(self.getContainer(off)) == 0;
    }
};

/// A key and an upper bound for the cardinality a union will give it: the sum
/// over the inputs, which is exact when they are disjoint.
const KeyEstimate = struct {
    key: u64,
    card: u32,

    fn lessThan(_: void, a: KeyEstimate, b: KeyEstimate) bool {
        return a.key < b.key;
    }
};

/// Sums the estimates of equal keys and drops the keys that stay empty.
/// `est` must be sorted by key; the merged prefix is returned.
fn mergeEstimates(est: []KeyEstimate) []KeyEstimate {
    var w: usize = 0;
    for (est) |e| {
        if (w > 0 and est[w - 1].key == e.key) {
            const sum = @as(u64, est[w - 1].card) + e.card;
            est[w - 1].card = @intCast(@min(sum, container.max_cardinality));
            continue;
        }
        est[w] = e;
        w += 1;
    }

    var live: usize = 0;
    for (est[0..w]) |e| {
        if (e.card == 0) continue;
        est[live] = e;
        live += 1;
    }
    return est[0..live];
}

/// Size of a container holding `count` values: the smallest array container
/// that fits, or a bitmap container when none does.
fn containerSizeFor(count: usize) u16 {
    return container.arraySizeFor(count) orelse container.max_size;
}

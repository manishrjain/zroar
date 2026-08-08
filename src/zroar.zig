//! zroar — serialized roaring bitmaps over u64 values.
//!
//! A bitmap is one flat, 8-byte-aligned buffer of u16s: a keys node followed by
//! containers. That buffer *is* the serialized form, so `fromBuffer` is O(1)
//! and allocation-free.
//!
//! Ported from https://github.com/dgraph-io/sroar; see DESIGN.md for the layout
//! and for the places where this port deliberately diverges.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

// The on-disk format is little-endian by definition. On little-endian targets
// (every supported one) reinterpreting the buffer IS the encoding, so this
// costs nothing. Big-endian targets would corrupt data silently; refuse them.
comptime {
    if (builtin.target.cpu.arch.endian() != .little)
        @compileError("zroar's on-disk format is little-endian; big-endian targets are unsupported");
}

const container = @import("container.zig");
const keys_mod = @import("keys.zig");

pub const Keys = keys_mod.Keys;
pub const Iterator = @import("iterator.zig").Iterator;
pub const setutil = @import("setutil.zig");

/// The high 48 bits of a value select its container.
pub const key_mask = keys_mod.key_mask;

/// Key/offset pairs a freshly initialized bitmap has room for.
const init_num_keys: usize = 2;

/// The keys node grows by doubling, capped at this many u16s per step. The cap
/// is a multiple of 4 so the node size stays 8-byte aligned.
const max_node_growth: usize = 65532;

/// The keys node header (node size, number of keys), in u16 units.
const node_header_size: usize = keys_mod.index_node_start * 4;

/// One (key, offset) pair of the keys node, in u16 units.
const key_pair_size: usize = 8;

/// Every bitmap has a keys node with room for at least two keys plus key 0's
/// minimum-size container, so no valid buffer is smaller than this.
const min_buffer_bytes: usize = 2 * (4 * (2 * init_num_keys + 2) + container.min_size);

pub const Bitmap = struct {
    /// The in-use region of the buffer, in u16 units.
    data: []align(8) u16,
    /// Allocated capacity in u16 units. Equals data.len for a borrowed buffer.
    cap: usize,
    /// False for a buffer handed to us by `fromBuffer`; true once we own it.
    owned: bool,
    allocator: std.mem.Allocator,

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
        @memset(buf, 0);

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
        const node_size: usize = @intCast(p[0]);
        assert(node_size % 4 == 0);
        assert(node_size >= 16 and node_size <= self.data.len);
        return .{ .n = p[0 .. node_size / 4] };
    }

    fn setNodeSize(self: *Bitmap, node_size: usize) void {
        const p: [*]u64 = @ptrCast(self.data.ptr);
        p[0] = node_size;
    }

    /// Internal: the container living at `offset`, sized by its own header.
    pub fn getContainer(self: *const Bitmap, offset: usize) []u16 {
        assert(offset % 4 == 0);
        const sz = self.data[offset];
        assert(sz >= container.min_size and sz <= container.max_size);
        return self.data[offset..][0..sz];
    }

    /// Grows the in-use region by `by_size` u16s, reallocating if needed.
    /// The newly exposed region is zeroed; Zig allocators do not zero for us.
    fn fastExpand(self: *Bitmap, by_size: usize) !void {
        const old_len = self.data.len;
        const to_size = old_len + by_size;

        if (to_size > self.cap) {
            const new_cap = self.cap + @max(self.cap, by_size);
            const out = try self.allocator.alignedAlloc(u16, .@"8", new_cap);
            @memcpy(out[0..old_len], self.data);
            // A borrowed buffer belongs to the caller; only free our own.
            if (self.owned) self.allocator.free(self.data.ptr[0..self.cap]);
            self.data = out.ptr[0..to_size];
            self.cap = new_cap;
            self.owned = true;
        } else {
            self.data = self.data.ptr[0..to_size];
        }
        @memset(self.data[old_len..to_size], 0);
    }

    /// Opens a zeroed hole of `by_size` u16s at `offset`. Container-unaware:
    /// the caller fixes up affected offsets via `Keys.updateOffsets`.
    fn scootRight(self: *Bitmap, offset: usize, by_size: usize) !void {
        const old_len = self.data.len;
        try self.fastExpand(by_size);
        std.mem.copyBackwards(
            u16,
            self.data[offset + by_size .. old_len + by_size],
            self.data[offset..old_len],
        );
        @memset(self.data[offset..][0..by_size], 0);
    }

    /// Appends a zeroed container of `sz` u16s and returns its offset.
    fn newContainer(self: *Bitmap, sz: u16) !usize {
        assert(sz % 4 == 0);
        const offset = self.data.len;
        assert(offset % 4 == 0);
        try self.fastExpand(sz);
        self.data[offset] = sz;
        return offset;
    }

    /// Doubles the container at `offset`, or converts it to a bitmap container
    /// once doubling would exceed the array-container ceiling.
    fn expandContainer(self: *Bitmap, offset: usize) !void {
        const sz = self.data[offset];
        // Only array containers ever grow; bitmap containers are already maximal.
        assert(sz >= container.min_size and sz <= container.max_array_size);

        const by_size: u16 = if (sz >= container.max_array_size)
            container.max_size - sz
        else
            sz;

        try self.scootRight(offset + sz, by_size);
        self.keys().updateOffsets(offset, by_size, true);

        if (sz < container.max_array_size) {
            self.data[offset] = sz + by_size;
        } else {
            self.data[offset] = container.max_size;
            container.array.toBitmap(self.getContainer(offset));
        }
    }

    /// Registers `offset` for `key`, returning the offset to use afterwards:
    /// growing the keys node shifts every container, including this one.
    fn setKey(self: *Bitmap, key: u64, offset: usize) !usize {
        if (!self.keys().set(key, offset)) return offset; // key already present
        if (!self.keys().isFull()) return offset;

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

    /// The next array-container size up from `sz`: the ladder doubling from
    /// container.min_size to max_array_size, and max_size beyond that, where only
    /// a bitmap container is left.
    fn stepSize(sz: u16) u16 {
        var i: u16 = container.min_size;
        while (i <= container.max_array_size / 2) : (i *= 2) {
            if (sz <= i) return i * 2;
        }
        return container.max_size;
    }

    /// Installs the container `src` at `offset`, growing the container already
    /// there when `src` no longer fits it — up to the full bitmap size, which
    /// also retypes it. Port of sroar's copyAt; it lands the results that
    /// `container.containerOr` had to build in its scratch buffer.
    fn copyAt(self: *Bitmap, offset: usize, src: []const u16) !void {
        const dst_size = self.data[offset];
        assert(dst_size >= container.min_size);

        if (container.getType(src) == .bitmap) {
            assert(container.size(src) == container.max_size);
            const by_size = container.max_size - dst_size;
            try self.scootRight(offset + dst_size, by_size);
            self.keys().updateOffsets(offset, by_size, true);
            @memcpy(self.data[offset..][0..container.max_size], src);
            return;
        }

        // An array result that already fits keeps the larger allocation: the
        // container's own size header must survive the copy.
        if (dst_size >= container.size(src)) {
            @memcpy(self.data[offset..][0..src.len], src);
            self.data[offset] = dst_size;
            return;
        }

        var target = stepSize(dst_size);
        while (target < container.size(src)) target = stepSize(target);
        // containerOr only ever builds array results that an array container can
        // hold, so the step never runs past the array ceiling.
        assert(target <= container.max_array_size);

        try self.scootRight(offset + dst_size, target - dst_size);
        self.keys().updateOffsets(offset, target - dst_size, true);
        @memcpy(self.data[offset..][0..src.len], src);
        self.data[offset] = target;
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

    /// Adds x. Returns true if it was not already present.
    pub fn set(self: *Bitmap, x: u64) !bool {
        const key = x & key_mask;
        const lo: u16 = @truncate(x);

        const offset = self.keys().getValue(key) orelse blk: {
            const fresh = try self.newContainer(container.min_size);
            break :blk try self.setKey(key, fresh);
        };

        const c = self.getContainer(offset);
        switch (container.getType(c)) {
            .array => {
                if (!container.array.add(c, lo)) return false;
                // Restore the free-slot invariant before anyone reads the container.
                if (container.array.isFull(c)) try self.expandContainer(offset);
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
    pub fn remove(self: *Bitmap, x: u64) bool {
        const offset = self.keys().getValue(x & key_mask) orelse return false;
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

    /// True when the bitmap holds no values. Cheaper than getCardinality() == 0.
    pub fn isEmpty(self: *const Bitmap) bool {
        const ks = self.keys();
        var i: usize = 0;
        while (i < ks.numKeys()) : (i += 1) {
            if (container.getCardinality(self.getContainer(ks.val(i))) > 0) return false;
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

        var it = self.iterator();
        var i: usize = 0;
        while (it.next()) |v| : (i += 1) out[i] = v;
        assert(i == out.len);
        return out;
    }

    /// A forward iterator. Valid only until the bitmap is mutated.
    pub fn iterator(self: *const Bitmap) Iterator {
        return Iterator.init(self);
    }

    // -----------------------------------------------------------------------
    // Serialization
    // -----------------------------------------------------------------------

    /// The bitmap's buffer, borrowed. O(1). Invalidated by any growth or deinit.
    pub fn toBuffer(self: *const Bitmap) []align(8) const u8 {
        const p: [*]align(8) const u8 = @ptrCast(self.data.ptr);
        return p[0 .. self.data.len * 2];
    }

    /// An owning copy of the bitmap's buffer.
    pub fn toBufferCopy(self: *const Bitmap, allocator: std.mem.Allocator) ![]align(8) u8 {
        const src = self.toBuffer();
        const out = try allocator.alignedAlloc(u8, .@"8", src.len);
        @memcpy(out, src);
        return out;
    }

    /// Wraps `buf` in O(1) without copying or validating it. The bitmap may be
    /// mutated: mutations that do not grow the buffer write through to `buf`,
    /// and the first growth copies out, leaving `buf` untouched from then on.
    /// `buf` must outlive the bitmap. Returns a fresh empty bitmap if `buf` is
    /// too small or oddly sized to be a bitmap at all.
    pub fn fromBuffer(allocator: std.mem.Allocator, buf: []align(8) u8) !Bitmap {
        if (buf.len % 2 != 0 or buf.len < min_buffer_bytes) return init(allocator);

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
    pub fn fromBufferCopy(allocator: std.mem.Allocator, buf: []const u8) !Bitmap {
        if (buf.len % 2 != 0 or buf.len < min_buffer_bytes) return init(allocator);

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
    /// Every key of `other` that self does not already have is inserted one at a
    /// time, and each insertion memmoves the tail of the keys node — O(numKeys)
    /// per new key, so O(n²) when the operands share few keys. That is the price
    /// of unioning *into* an existing bitmap. A caller that only wants the union
    /// as a new bitmap should use `Or` or `fastOr`, which size the keys node for
    /// the whole result before creating any of it.
    pub fn orInPlace(self: *Bitmap, other: *const Bitmap) !void {
        const buf = try self.allocator.alignedAlloc(u16, .@"8", container.max_size);
        defer self.allocator.free(buf);
        try self.orWith(other, buf, false);
    }

    /// The body shared by orInPlace, Or and fastOr. `buf` is one scratch
    /// container for the merges that cannot run in place. In `lazy` mode
    /// bitmap containers are left with an invalid cardinality, which the
    /// caller must repair before the bitmap is handed out.
    fn orWith(self: *Bitmap, other: *const Bitmap, buf: []align(8) u16, lazy: bool) !void {
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
                try self.copyAt(offset, src);
                continue;
            }
            const offset = ks.val(idx);
            if (container.containerOr(self.getContainer(offset), src, buf, lazy)) |c| {
                // The union outgrew the container; install what was built in buf.
                try self.copyAt(offset, c);
            }
        }
    }

    /// a ∩ b as a new bitmap owned by the caller.
    ///
    /// The cost is proportional to the *output*: a key that intersects to
    /// nothing costs one merge step and no space at all, and every container is
    /// created at the size its own result needs. So there is nothing to compact
    /// afterwards — unlike sroar, which copies a's containers in whole only to
    /// shrink them again and then sweeps the empties away.
    pub fn And(allocator: std.mem.Allocator, a: *const Bitmap, b: *const Bitmap) !Bitmap {
        var res = try init(allocator);
        errdefer res.deinit();
        // Room for every shared key up front: the keys below then go into a node
        // that never grows, so no container ever has to move.
        try res.initSpaceForKeys(countSharedKeys(a, b));

        // One scratch container per call. The intersection cannot be computed in
        // place, since neither operand may be touched, and its size is not known
        // until it has been computed.
        var scratch: [container.max_size]u16 align(8) = undefined;

        const ka = a.keys();
        const kb = b.keys();
        var ai: usize = 0;
        var bi: usize = 0;
        while (ai < ka.numKeys() and bi < kb.numKeys()) {
            const ak = ka.key(ai);
            const bk = kb.key(bi); // sroar reads a.keys here; that is Go bug 1
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
            if (container.getCardinality(built) > 0) try res.appendResult(ak, built);
            ai += 1;
            bi += 1;
        }
        return res;
    }

    // -----------------------------------------------------------------------
    // Fused cardinalities
    //
    // "How big would this operation's result be?" answered without producing the
    // result: one merge walk over the two key lists, and for the keys they share
    // `container.containerAndCardinality`, which counts an overlap in place. No
    // allocation, so none of the three can fail, and no bitmap is built and
    // thrown away. CRoaring offers the same three as
    // roaring64_bitmap_{and,or,andnot}_cardinality.
    // -----------------------------------------------------------------------

    /// |self ∩ other|. Keys held by only one side intersect to nothing, so only
    /// the shared ones cost anything at all.
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
                total += container.getCardinality(self.getContainer(ka.val(ai)));
                ai += 1;
            } else if (ak > bk) {
                total += container.getCardinality(other.getContainer(kb.val(bi)));
                bi += 1;
            } else {
                const ca = self.getContainer(ka.val(ai));
                const cb = other.getContainer(kb.val(bi));
                total += container.getCardinality(ca) + container.getCardinality(cb) -
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
                total += container.getCardinality(self.getContainer(ka.val(ai)));
                ai += 1;
            } else if (ak > bk) {
                bi += 1;
            } else {
                const ca = self.getContainer(ka.val(ai));
                total += container.getCardinality(ca) - container.containerAndCardinality(
                    ca,
                    other.getContainer(kb.val(bi)),
                );
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
    /// A bitmap-shaped result small enough for an array container is written out
    /// as an array container. That picks the shape of a container as it is
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
                @memcpy(dst[container.start_idx..][0..card], container.array.values(built));
                container.setCardinality(dst, card);
            },
            .bitmap => if (sz == container.max_size)
                @memcpy(dst, built) // both are full bitmap containers
            else
                container.bitmap.toArrayInto(dst, built),
        }
    }

    /// Grows the container at `offset` to exactly `sz` u16s, leaving the extra
    /// room zeroed. `sz` must not be smaller than the container's current size.
    fn growContainerTo(self: *Bitmap, offset: usize, sz: u16) !void {
        const cur = self.data[offset];
        if (cur >= sz) return;
        try self.scootRight(offset + cur, sz - cur);
        self.keys().updateOffsets(offset, sz - cur, true);
        self.data[offset] = sz;
    }

    /// a ∪ b as a new bitmap owned by the caller.
    ///
    /// The two-operand union is just `fastOr` of two inputs, and it has to be:
    /// unioning `a` and then `b` into a fresh bitmap inserts every key of `b`
    /// that `a` lacks one at a time, and each insertion memmoves the keys node
    /// (see `orInPlace`). On key-disjoint operands with half a million keys each
    /// that quadratic term dominates everything else by two orders of magnitude.
    /// `fastOr` instead sums the per-key cardinalities of both inputs first,
    /// builds the whole keys node in one pass, and lets each container be created
    /// at a size its result already fits in.
    ///
    /// Like any `fastOr` result this one may carry a single container that no key
    /// points at, left behind when key 0 needed a bigger container than the one
    /// `init` gave it. That is dead space, not corruption; `cleanup` reclaims it.
    pub fn Or(allocator: std.mem.Allocator, a: *const Bitmap, b: *const Bitmap) !Bitmap {
        return fastOr(allocator, &.{ a, b });
    }

    /// The union of many bitmaps as a new bitmap owned by the caller. Faster
    /// than folding `orInPlace`: the keys and the containers of the result are
    /// sized up front from the summed cardinalities, so no key insertion has to
    /// move the containers, and each container's cardinality is counted once at
    /// the end rather than after every input.
    pub fn fastOr(allocator: std.mem.Allocator, bitmaps: []const *const Bitmap) !Bitmap {
        if (bitmaps.len == 0) return init(allocator);
        // sroar hands back the input itself here; the result must be the
        // caller's to own and to keep mutating, so copy it.
        if (bitmaps.len == 1) return fromBufferCopy(allocator, bitmaps[0].toBuffer());

        // Every (key, cardinality) pair of every input, sorted by key and then
        // merged. sroar uses a map here; one sort is simpler and allocates once.
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
                scratch[n] = .{ .key = ks.key(i), .card = container.getCardinality(c) };
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
                if (bitmap_pass) container.setType(dst.getContainer(offset), .bitmap);
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
    pub fn fromSortedList(allocator: std.mem.Allocator, vals: []const u64) !Bitmap {
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
                assert(j == 0 or vals[j] >= vals[j - 1]); // the input must be sorted
                if (j == i or vals[j] != vals[j - 1]) distinct += 1;
            }
            try bm.fillContainer(key, vals[i..j], distinct);
            i = j;
        }
        return bm;
    }

    /// Writes one run of `vals` — all sharing `key`, ascending, `distinct` of
    /// them unique — into a single container sized for exactly that run.
    fn fillContainer(self: *Bitmap, key: u64, vals: []const u64, distinct: usize) !void {
        const sz = containerSizeFor(distinct);
        const offset = try self.addContainer(key, sz);
        const c = self.getContainer(offset);

        if (sz == container.max_size) {
            container.setType(c, .bitmap);
            const w = container.bitmap.words(c);
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
    /// andNotInPlace or remove, together with its key. Key 0 always survives.
    ///
    /// Allocation-free: sroar collects the removed ranges into slices and sorts
    /// them; walking the buffer left to right instead needs no bookkeeping and
    /// merges neighbouring holes just as well.
    pub fn cleanup(self: *Bitmap) void {
        // Keys first: while they still point at their own containers, an empty
        // container can be told apart from a live one by its cardinality alone.
        self.cleanupKeys();
        self.cleanupContainers();
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
        // Clear the pair slots that are spare capacity now, keeping the buffer
        // canonical, then drop the tail of the node the pairs no longer need.
        @memset(self.data[node_header_size + key_pair_size * w .. new_size], 0);
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
            while (off + run < self.data.len and self.isDeadContainer(off + run)) {
                run += self.data[off + run];
            }
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test {
    // container.zig is the only file that calls into setutil, and it does so
    // through a few functions only; pull the whole file in so that its own
    // tests are compiled and run too.
    _ = setutil;
}

/// Type of the container holding `x`'s key. Test-only introspection.
fn containerTypeOf(bm: *const Bitmap, x: u64) container.Type {
    const offset = bm.keys().getValue(x & key_mask).?;
    return container.getType(bm.getContainer(offset));
}

/// Asserts the layout invariants DESIGN.md calls load-bearing.
fn checkInvariants(bm: *const Bitmap) !void {
    const ks = bm.keys();
    try testing.expect(ks.size() % 4 == 0);
    try testing.expect(ks.numKeys() >= 1);
    try testing.expectEqual(@as(u64, 0), ks.key(0)); // key 0 always exists

    var i: usize = 0;
    while (i < ks.numKeys()) : (i += 1) {
        if (i > 0) try testing.expect(ks.key(i) > ks.key(i - 1));
        try testing.expectEqual(ks.key(i) & key_mask, ks.key(i));

        const off = ks.val(i);
        try testing.expectEqual(@as(usize, 0), off % 4);
        try testing.expect(off >= ks.size());

        const c = bm.getContainer(off);
        try testing.expectEqual(@as(u16, 0), container.size(c) % 4);
        switch (container.getType(c)) {
            // Free-slot invariant: an array container is never observed full.
            .array => try testing.expect(!container.array.isFull(c)),
            .bitmap => {
                try testing.expectEqual(container.max_size, container.size(c));
                try testing.expectEqual(container.getCardinality(c), container.bitmap.cardinality(c));
            },
        }
    }
}

test "init creates an empty bitmap with key 0" {
    var bm = try Bitmap.init(testing.allocator);
    defer bm.deinit();

    try testing.expect(bm.isEmpty());
    try testing.expectEqual(@as(u64, 0), bm.getCardinality());
    try testing.expectEqual(@as(usize, 1), bm.keys().numKeys());
    try testing.expectEqual(@as(?u64, null), bm.minimum());
    try testing.expectEqual(@as(?u64, null), bm.maximum());
    try testing.expect(!bm.contains(0));
    try checkInvariants(&bm);
}

test "set, contains and remove around key 0" {
    var bm = try Bitmap.init(testing.allocator);
    defer bm.deinit();

    try testing.expect(try bm.set(0));
    try testing.expect(!try bm.set(0)); // already present
    try testing.expect(bm.contains(0));
    try testing.expect(!bm.isEmpty());
    try testing.expectEqual(@as(u64, 1), bm.getCardinality());
    try testing.expectEqual(@as(?u64, 0), bm.minimum());
    try testing.expectEqual(@as(?u64, 0), bm.maximum());
    try testing.expectEqual(@as(usize, 1), bm.keys().numKeys()); // no key added

    try testing.expect(try bm.set(0xFFFF));
    try testing.expectEqual(@as(?u64, 0xFFFF), bm.maximum());

    try testing.expect(bm.remove(0));
    try testing.expect(!bm.remove(0));
    try testing.expect(!bm.contains(0));
    try testing.expectEqual(@as(?u64, 0xFFFF), bm.minimum());

    try testing.expect(bm.remove(0xFFFF));
    try testing.expect(bm.isEmpty());
    try testing.expectEqual(@as(?u64, null), bm.minimum());
    try checkInvariants(&bm);
}

test "sequential sets cross the array to bitmap conversion" {
    var bm = try Bitmap.init(testing.allocator);
    defer bm.deinit();

    // 2044 values is the array-container ceiling; go well past it.
    const n = 3000;
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        try testing.expect(try bm.set(i));
        try testing.expectEqual(i + 1, bm.getCardinality());
    }
    try testing.expectEqual(container.Type.bitmap, containerTypeOf(&bm, 0));
    try checkInvariants(&bm);

    i = 0;
    while (i < n) : (i += 1) try testing.expect(bm.contains(i));
    try testing.expect(!bm.contains(n));
    try testing.expectEqual(@as(?u64, 0), bm.minimum());
    try testing.expectEqual(@as(?u64, n - 1), bm.maximum());
}

test "conversion happens exactly at the array ceiling" {
    var bm = try Bitmap.init(testing.allocator);
    defer bm.deinit();

    // Container sizes double up to 2048, which holds 2044 values, and the
    // 2044th insert fills it, which triggers the bitmap conversion.
    var i: u64 = 0;
    while (i < container.max_array_values - 1) : (i += 1) _ = try bm.set(i);
    try testing.expectEqual(container.Type.array, containerTypeOf(&bm, 0));

    _ = try bm.set(i);
    try testing.expectEqual(container.Type.bitmap, containerTypeOf(&bm, 0));
    try testing.expectEqual(@as(u64, container.max_array_values), bm.getCardinality());
    try checkInvariants(&bm);

    var j: u64 = 0;
    while (j < container.max_array_values) : (j += 1) try testing.expect(bm.contains(j));
}

test "random sets crossing the conversion agree with a reference set" {
    var bm = try Bitmap.init(testing.allocator);
    defer bm.deinit();

    var ref = std.AutoHashMapUnmanaged(u64, void).empty;
    defer ref.deinit(testing.allocator);

    var prng = std.Random.DefaultPrng.init(0x5EED_1234);
    const rnd = prng.random();

    var i: usize = 0;
    while (i < 20_000) : (i += 1) {
        const x = rnd.uintLessThan(u64, 1 << 16);
        const added = try bm.set(x);
        const gop = try ref.getOrPut(testing.allocator, x);
        try testing.expectEqual(!gop.found_existing, added);
    }
    try testing.expectEqual(@as(u64, ref.count()), bm.getCardinality());
    try testing.expectEqual(container.Type.bitmap, containerTypeOf(&bm, 0));
    try checkInvariants(&bm);

    var x: u64 = 0;
    while (x < 1 << 16) : (x += 1) {
        try testing.expectEqual(ref.contains(x), bm.contains(x));
    }
}

test "values above 2^32 and 2^48 land in distinct containers" {
    var bm = try Bitmap.init(testing.allocator);
    defer bm.deinit();

    const vals = [_]u64{
        0,
        0xFFFF,
        1 << 16,
        (1 << 32) | 5,
        (1 << 32) | 0xFFFF,
        (1 << 48) | 7,
        (1 << 48) | (1 << 32),
        std.math.maxInt(u64),
        std.math.maxInt(u64) - 1,
    };
    for (vals) |v| try testing.expect(try bm.set(v));
    try testing.expectEqual(@as(u64, vals.len), bm.getCardinality());
    for (vals) |v| try testing.expect(bm.contains(v));

    try testing.expect(!bm.contains(1));
    try testing.expect(!bm.contains((1 << 32) | 6));
    try testing.expect(!bm.contains(1 << 47));
    try testing.expectEqual(@as(?u64, 0), bm.minimum());
    try testing.expectEqual(@as(?u64, std.math.maxInt(u64)), bm.maximum());
    try checkInvariants(&bm);

    // Three pairs share a key: {0, 0xFFFF}, the two 1<<32 values, and the two
    // maxInt values.
    try testing.expectEqual(@as(usize, vals.len - 3), bm.keys().numKeys());
}

test "hundreds of keys force repeated keys-node growth" {
    var bm = try Bitmap.init(testing.allocator);
    defer bm.deinit();

    // Keys are inserted out of order so the node also exercises moveRight.
    const num_keys = 600;
    const per_key = 3;
    var step: u64 = 0;
    while (step < num_keys) : (step += 1) {
        const k = (step * 397) % num_keys; // 397 is coprime with 600
        var j: u64 = 0;
        while (j < per_key) : (j += 1) {
            try testing.expect(try bm.set((k << 16) | (j * 1000)));
        }
    }

    try testing.expectEqual(@as(usize, num_keys), bm.keys().numKeys());
    try testing.expectEqual(@as(u64, num_keys * per_key), bm.getCardinality());
    try checkInvariants(&bm);

    // Every offset must still point at the right container after all the shifts.
    var k: u64 = 0;
    while (k < num_keys) : (k += 1) {
        var j: u64 = 0;
        while (j < per_key) : (j += 1) {
            try testing.expect(bm.contains((k << 16) | (j * 1000)));
        }
        try testing.expect(!bm.contains((k << 16) | 1));
    }
}

test "a container walks the whole size ladder one value at a time" {
    // The smallest container holds only a handful of values, so the very first
    // sets already exercise insert-then-expand; walk far enough to cross every
    // rung of the ladder and check the invariants after each single insert.
    var bm = try Bitmap.init(testing.allocator);
    defer bm.deinit();

    // A second key, so that growing key 0's container has to move something and
    // the offsets are checked rather than trivially unchanged.
    _ = try bm.set(1 << 32);

    var seen_sizes = std.AutoHashMapUnmanaged(u16, void).empty;
    defer seen_sizes.deinit(testing.allocator);

    var i: u64 = 0;
    while (i < container.max_array_values + 8) : (i += 1) {
        try testing.expect(try bm.set(i * 3));
        try testing.expectEqual(i + 2, bm.getCardinality());
        try checkInvariants(&bm); // includes the free-slot invariant
        try testing.expect(bm.contains(1 << 32)); // the neighbour still resolves

        const c = bm.getContainer(bm.keys().val(0));
        try seen_sizes.put(testing.allocator, container.size(c), {});

        // Every value set so far is still there, wherever the container moved.
        var j: u64 = 0;
        while (j <= i) : (j += 1) try testing.expect(bm.contains(j * 3));
    }

    // Every rung of the ladder was visited, and the last step was the bitmap.
    var sz = container.min_size;
    while (sz <= container.max_array_size) : (sz *= 2) {
        try testing.expect(seen_sizes.contains(sz));
    }
    try testing.expect(seen_sizes.contains(container.max_size));
    try testing.expectEqual(container.Type.bitmap, containerTypeOf(&bm, 0));
}

test "the smallest container fills and expands at exactly its capacity" {
    var bm = try Bitmap.init(testing.allocator);
    defer bm.deinit();

    // min_size - start_idx values fit, but the last of them leaves no free slot,
    // so `set` must expand before returning: a reader never sees a full container.
    const capacity = container.min_size - container.start_idx;
    var i: u64 = 0;
    while (i + 1 < capacity) : (i += 1) {
        _ = try bm.set(i);
        try testing.expectEqual(container.min_size, container.size(bm.getContainer(bm.keys().val(0))));
        try checkInvariants(&bm);
    }
    _ = try bm.set(i);
    try testing.expectEqual(container.min_size * 2, container.size(bm.getContainer(bm.keys().val(0))));
    try testing.expectEqual(@as(u64, capacity), bm.getCardinality());
    try checkInvariants(&bm);
}

test "keys-node growth past the doubling cap stays 8-byte aligned" {
    var bm = try Bitmap.init(testing.allocator);
    defer bm.deinit();

    // The node doubles 24, 48, ... 98304 u16s; the step beyond that is capped at
    // max_node_growth. 98304 u16s is 12287 key/offset pairs, so one more key
    // than that exercises the capped path.
    const num_keys = 12_400;
    var k: u64 = 0;
    while (k < num_keys) : (k += 1) _ = try bm.set(k << 16);

    try testing.expectEqual(@as(usize, num_keys), bm.keys().numKeys());
    // Uncapped doubling would have produced 196608 u16s here.
    try testing.expectEqual(@as(usize, 98304 + max_node_growth), bm.keys().size());
    try checkInvariants(&bm);

    k = 0;
    while (k < num_keys) : (k += 1) try testing.expect(bm.contains(k << 16));
}

test "keys-node growth interleaved with container growth" {
    var bm = try Bitmap.init(testing.allocator);
    defer bm.deinit();

    // Each key gets enough values to promote its container to a bitmap, while
    // new keys keep pushing the node to grow underneath them.
    const num_keys = 8;
    var k: u64 = 0;
    while (k < num_keys) : (k += 1) {
        var j: u64 = 0;
        while (j < 2500) : (j += 1) _ = try bm.set((k << 16) | j);
    }
    try testing.expectEqual(@as(u64, num_keys * 2500), bm.getCardinality());
    try checkInvariants(&bm);

    k = 0;
    while (k < num_keys) : (k += 1) {
        try testing.expectEqual(container.Type.bitmap, containerTypeOf(&bm, k << 16));
        var j: u64 = 0;
        while (j < 2500) : (j += 1) try testing.expect(bm.contains((k << 16) | j));
        try testing.expect(!bm.contains((k << 16) | 2500));
    }
}

test "remove from both container types" {
    var bm = try Bitmap.init(testing.allocator);
    defer bm.deinit();

    // Key 0 stays an array container, key 1 is promoted to a bitmap.
    var i: u64 = 0;
    while (i < 100) : (i += 1) _ = try bm.set(i);
    while (i < 100 + 3000) : (i += 1) _ = try bm.set((1 << 16) | (i - 100));
    try testing.expectEqual(container.Type.array, containerTypeOf(&bm, 0));
    try testing.expectEqual(container.Type.bitmap, containerTypeOf(&bm, 1 << 16));

    try testing.expect(bm.remove(50));
    try testing.expect(!bm.remove(50));
    try testing.expect(!bm.contains(50));
    try testing.expect(bm.contains(49) and bm.contains(51));

    try testing.expect(bm.remove((1 << 16) | 2000));
    try testing.expect(!bm.remove((1 << 16) | 2000));
    try testing.expect(!bm.contains((1 << 16) | 2000));

    try testing.expect(!bm.remove(1 << 32)); // key not present at all
    try testing.expectEqual(@as(u64, 100 + 3000 - 2), bm.getCardinality());
    try checkInvariants(&bm);

    // Emptying a container must not disturb minimum/maximum of the others.
    i = 0;
    while (i < 100) : (i += 1) _ = bm.remove(i);
    try testing.expectEqual(@as(?u64, 1 << 16), bm.minimum());
}

test "iterator over an empty bitmap" {
    var bm = try Bitmap.init(testing.allocator);
    defer bm.deinit();

    var it = bm.iterator();
    try testing.expectEqual(@as(?u64, null), it.next());
    try testing.expectEqual(@as(?u64, null), it.next());
}

test "iterator emits value 0 from a bitmap container" {
    var bm = try Bitmap.init(testing.allocator);
    defer bm.deinit();

    // Promote key 0's container to a bitmap while keeping the value 0 in it.
    var i: u64 = 0;
    while (i < 3000) : (i += 1) _ = try bm.set(i);
    try testing.expectEqual(container.Type.bitmap, containerTypeOf(&bm, 0));

    var it = bm.iterator();
    try testing.expectEqual(@as(?u64, 0), it.next()); // not an end sentinel
    var expected: u64 = 1;
    while (expected < 3000) : (expected += 1) {
        try testing.expectEqual(@as(?u64, expected), it.next());
    }
    try testing.expectEqual(@as(?u64, null), it.next());
}

test "iterator emits value 0 from an array container" {
    var bm = try Bitmap.init(testing.allocator);
    defer bm.deinit();

    _ = try bm.set(0);
    _ = try bm.set(1 << 32);
    try testing.expectEqual(container.Type.array, containerTypeOf(&bm, 0));

    var it = bm.iterator();
    try testing.expectEqual(@as(?u64, 0), it.next());
    try testing.expectEqual(@as(?u64, 1 << 32), it.next());
    try testing.expectEqual(@as(?u64, null), it.next());
}

test "iterator skips empty containers" {
    var bm = try Bitmap.init(testing.allocator);
    defer bm.deinit();

    _ = try bm.set(5);
    _ = try bm.set(1 << 16);
    _ = try bm.set(2 << 16);
    _ = bm.remove(1 << 16); // leaves an empty container in the middle

    var it = bm.iterator();
    try testing.expectEqual(@as(?u64, 5), it.next());
    try testing.expectEqual(@as(?u64, 2 << 16), it.next());
    try testing.expectEqual(@as(?u64, null), it.next());
}

test "toArray is sorted and matches the reference set" {
    var bm = try Bitmap.init(testing.allocator);
    defer bm.deinit();

    var ref = std.ArrayListUnmanaged(u64).empty;
    defer ref.deinit(testing.allocator);

    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rnd = prng.random();
    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        // Mix a dense low region (bitmap containers) with scattered high keys.
        const x = if (i % 2 == 0)
            rnd.uintLessThan(u64, 4096)
        else
            (rnd.uintLessThan(u64, 40) << 48) | rnd.uintLessThan(u64, 1 << 16);
        if (try bm.set(x)) try ref.append(testing.allocator, x);
    }
    std.mem.sort(u64, ref.items, {}, std.sort.asc(u64));

    const got = try bm.toArray(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u64, ref.items, got);
    try testing.expectEqual(@as(?u64, ref.items[0]), bm.minimum());
    try testing.expectEqual(@as(?u64, ref.items[ref.items.len - 1]), bm.maximum());
    try checkInvariants(&bm);
}

test "toArray on an empty bitmap" {
    var bm = try Bitmap.init(testing.allocator);
    defer bm.deinit();

    const got = try bm.toArray(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "round trip through a buffer is bit identical" {
    var bm = try Bitmap.init(testing.allocator);
    defer bm.deinit();

    var i: u64 = 0;
    while (i < 3000) : (i += 1) _ = try bm.set(i * 7);
    _ = try bm.set(std.math.maxInt(u64));

    const buf = try bm.toBufferCopy(testing.allocator);
    defer testing.allocator.free(buf);

    var reopened = try Bitmap.fromBuffer(testing.allocator, buf);
    defer reopened.deinit();

    try testing.expectEqualSlices(u16, bm.data, reopened.data);
    try testing.expectEqual(bm.getCardinality(), reopened.getCardinality());
    try testing.expectEqual(bm.minimum(), reopened.minimum());
    try testing.expectEqual(bm.maximum(), reopened.maximum());
    try checkInvariants(&reopened);

    const a = try bm.toArray(testing.allocator);
    defer testing.allocator.free(a);
    const b = try reopened.toArray(testing.allocator);
    defer testing.allocator.free(b);
    try testing.expectEqualSlices(u64, a, b);
}

test "empty bitmap round trip" {
    var bm = try Bitmap.init(testing.allocator);
    defer bm.deinit();

    const buf = try bm.toBufferCopy(testing.allocator);
    defer testing.allocator.free(buf);
    try testing.expect(buf.len > 0); // no null special case

    var reopened = try Bitmap.fromBuffer(testing.allocator, buf);
    defer reopened.deinit();
    try testing.expect(reopened.isEmpty());
    try testing.expectEqual(@as(u64, 0), reopened.getCardinality());
    try testing.expectEqual(@as(?u64, null), reopened.minimum());
    var it = reopened.iterator();
    try testing.expectEqual(@as(?u64, null), it.next());

    // Still usable for further sets.
    try testing.expect(try reopened.set(42));
    try testing.expect(reopened.contains(42));
}

test "fromBuffer rejects buffers too small to be a bitmap" {
    var odd: [min_buffer_bytes + 1]u8 align(8) = .{0} ** (min_buffer_bytes + 1);
    var short: [min_buffer_bytes - 2]u8 align(8) = .{0} ** (min_buffer_bytes - 2);

    var a = try Bitmap.fromBuffer(testing.allocator, &odd);
    defer a.deinit();
    try testing.expect(a.owned and a.isEmpty());

    var b = try Bitmap.fromBuffer(testing.allocator, &short);
    defer b.deinit();
    try testing.expect(b.owned and b.isEmpty());

    var c = try Bitmap.fromBufferCopy(testing.allocator, &.{});
    defer c.deinit();
    try testing.expect(c.owned and c.isEmpty());
}

test "mutating a borrowed bitmap without growth writes through" {
    var src = try Bitmap.init(testing.allocator);
    defer src.deinit();
    // Two values, so that key 0's container still has room for a third whatever
    // container.min_size is: it is a power of two above the 4-u16 header, so the
    // smallest container has at least four slots and three values never fill it.
    _ = try src.set(1);
    _ = try src.set(2);

    const buf = try src.toBufferCopy(testing.allocator);
    defer testing.allocator.free(buf);

    {
        // Key 0's array container has a free slot, so this set never grows.
        var view = try Bitmap.fromBuffer(testing.allocator, buf);
        defer view.deinit();
        const cap_before = view.cap;
        try testing.expect(try view.set(3));
        try testing.expect(!view.owned); // no copy-out happened
        try testing.expectEqual(cap_before, view.cap);
    }

    // The change is visible in the caller's buffer.
    var again = try Bitmap.fromBuffer(testing.allocator, buf);
    defer again.deinit();
    try testing.expect(again.contains(3));
    try testing.expectEqual(@as(u64, 3), again.getCardinality());
}

test "growing a borrowed bitmap copies out and leaves the buffer untouched" {
    var src = try Bitmap.init(testing.allocator);
    defer src.deinit();
    _ = try src.set(1);
    _ = try src.set(2);

    const buf = try src.toBufferCopy(testing.allocator);
    defer testing.allocator.free(buf);
    const pristine = try testing.allocator.dupe(u8, buf);
    defer testing.allocator.free(pristine);

    var view = try Bitmap.fromBuffer(testing.allocator, buf);
    defer view.deinit();
    try testing.expect(!view.owned);

    // A brand new key allocates a container, which grows the buffer before
    // anything is written, so the borrowed buffer is never touched.
    try testing.expect(try view.set(1 << 48));
    try testing.expect(view.owned);

    try testing.expectEqualSlices(u8, pristine, buf);
    try testing.expect(view.contains(1));
    try testing.expect(view.contains(2));
    try testing.expect(view.contains(1 << 48));
    try testing.expectEqual(@as(u64, 3), view.getCardinality());
    try checkInvariants(&view);

    // The untouched buffer still reads back as the original bitmap.
    var reread = try Bitmap.fromBuffer(testing.allocator, buf);
    defer reread.deinit();
    try testing.expectEqual(@as(u64, 2), reread.getCardinality());
    try testing.expect(!reread.contains(1 << 48));
}

test "a grown borrowed bitmap keeps growing correctly" {
    var src = try Bitmap.init(testing.allocator);
    defer src.deinit();
    _ = try src.set(9);

    const buf = try src.toBufferCopy(testing.allocator);
    defer testing.allocator.free(buf);

    var view = try Bitmap.fromBuffer(testing.allocator, buf);
    defer view.deinit();

    // Enough work to force many reallocations and a container conversion.
    var i: u64 = 0;
    while (i < 5000) : (i += 1) _ = try view.set((i % 50 << 32) | i);
    try testing.expect(view.owned);
    try testing.expect(view.contains(9));
    try checkInvariants(&view);

    i = 0;
    while (i < 5000) : (i += 1) try testing.expect(view.contains((i % 50 << 32) | i));
}

test "fromBufferCopy owns its data and tolerates unaligned input" {
    var src = try Bitmap.init(testing.allocator);
    defer src.deinit();
    var i: u64 = 0;
    while (i < 500) : (i += 1) _ = try src.set(i * 3);

    const buf = try src.toBufferCopy(testing.allocator);
    defer testing.allocator.free(buf);

    // Copy into a deliberately misaligned window to prove no alignment is assumed.
    const scratch = try testing.allocator.alloc(u8, buf.len + 2);
    defer testing.allocator.free(scratch);
    @memcpy(scratch[2..], buf);

    var copy = try Bitmap.fromBufferCopy(testing.allocator, scratch[2..]);
    defer copy.deinit();
    try testing.expect(copy.owned);
    try testing.expectEqualSlices(u16, src.data, copy.data);

    // Mutating the copy must not touch the source buffer.
    _ = try copy.set(1 << 48);
    try testing.expectEqualSlices(u8, buf, scratch[2..]);
    try testing.expectEqual(@as(u64, 501), copy.getCardinality());
    try testing.expectEqual(@as(u64, 500), src.getCardinality());
}

test "clone is independent of the original" {
    var bm = try Bitmap.init(testing.allocator);
    defer bm.deinit();
    var i: u64 = 0;
    while (i < 3000) : (i += 1) _ = try bm.set(i);
    _ = try bm.set(1 << 40);

    var cloned = try bm.clone();
    defer cloned.deinit();
    try testing.expectEqualSlices(u16, bm.data, cloned.data);
    try testing.expectEqual(bm.getCardinality(), cloned.getCardinality());

    _ = try cloned.set(1 << 50);
    _ = bm.remove(0);
    try testing.expect(cloned.contains(1 << 50));
    try testing.expect(cloned.contains(0));
    try testing.expect(!bm.contains(1 << 50));
    try testing.expect(!bm.contains(0));
    try checkInvariants(&cloned);
}

// ---------------------------------------------------------------------------
// Set operation tests
// ---------------------------------------------------------------------------

const RefSet = std.AutoHashMapUnmanaged(u64, void);

/// A bitmap holding exactly `vals`, in any order.
fn testBitmap(vals: []const u64) !Bitmap {
    var bm = try Bitmap.init(testing.allocator);
    errdefer bm.deinit();
    for (vals) |v| _ = try bm.set(v);
    return bm;
}

fn testRefSet(vals: []const u64) !RefSet {
    var ref = RefSet.empty;
    errdefer ref.deinit(testing.allocator);
    for (vals) |v| try ref.put(testing.allocator, v, {});
    return ref;
}

/// Values spread over dense low keys (bitmap containers), a handful of sparse
/// keys, and keys above 2^32 and 2^48, so both container types and multi-level
/// keys are exercised.
fn randomValues(rnd: std.Random, out: []u64) void {
    for (out) |*v| {
        const low = rnd.uintLessThan(u64, 1 << 16);
        v.* = switch (rnd.uintLessThan(u8, 4)) {
            0 => rnd.uintLessThan(u64, 4096),
            1 => (rnd.uintLessThan(u64, 4) << 16) | low,
            2 => (rnd.uintLessThan(u64, 3) << 32) | low,
            else => (rnd.uintLessThan(u64, 3) << 48) | low,
        };
    }
}

fn refAnd(a: *const RefSet, b: *const RefSet) !RefSet {
    var out = RefSet.empty;
    errdefer out.deinit(testing.allocator);
    var it = a.keyIterator();
    while (it.next()) |k| {
        if (b.contains(k.*)) try out.put(testing.allocator, k.*, {});
    }
    return out;
}

fn refAndNot(a: *const RefSet, b: *const RefSet) !RefSet {
    var out = RefSet.empty;
    errdefer out.deinit(testing.allocator);
    var it = a.keyIterator();
    while (it.next()) |k| {
        if (!b.contains(k.*)) try out.put(testing.allocator, k.*, {});
    }
    return out;
}

fn refOr(a: *const RefSet, b: *const RefSet) !RefSet {
    var out = RefSet.empty;
    errdefer out.deinit(testing.allocator);
    for ([_]*const RefSet{ a, b }) |set| {
        var it = set.keyIterator();
        while (it.next()) |k| try out.put(testing.allocator, k.*, {});
    }
    return out;
}

/// The bitmap holds exactly the reference set's values, and its layout is sound.
fn expectSameAs(ref: *const RefSet, bm: *const Bitmap) !void {
    try testing.expectEqual(@as(u64, ref.count()), bm.getCardinality());

    var it = ref.keyIterator();
    while (it.next()) |k| try testing.expect(bm.contains(k.*));

    // The other direction, which also proves the iterator stays sorted.
    var seen: usize = 0;
    var prev: ?u64 = null;
    var bit = bm.iterator();
    while (bit.next()) |v| : (seen += 1) {
        try testing.expect(ref.contains(v));
        if (prev) |p| try testing.expect(v > p);
        prev = v;
    }
    try testing.expectEqual(@as(usize, ref.count()), seen);
    try testing.expectEqual(ref.count() == 0, bm.isEmpty());
    try checkInvariants(bm);
}

test "andInPlace and And against a reference set" {
    var prng = std.Random.DefaultPrng.init(0xA11CE);
    const rnd = prng.random();

    var round: usize = 0;
    while (round < 8) : (round += 1) {
        var av: [1500]u64 = undefined;
        var bv: [1500]u64 = undefined;
        randomValues(rnd, &av);
        randomValues(rnd, &bv);

        var a = try testBitmap(&av);
        defer a.deinit();
        var b = try testBitmap(&bv);
        defer b.deinit();
        var ra = try testRefSet(&av);
        defer ra.deinit(testing.allocator);
        var rb = try testRefSet(&bv);
        defer rb.deinit(testing.allocator);

        var want = try refAnd(&ra, &rb);
        defer want.deinit(testing.allocator);

        var in_place = try a.clone();
        defer in_place.deinit();
        in_place.andInPlace(&b);
        try expectSameAs(&want, &in_place);

        // cleanup must not change what the bitmap holds.
        in_place.cleanup();
        try expectSameAs(&want, &in_place);

        var two_op = try Bitmap.And(testing.allocator, &a, &b);
        defer two_op.deinit();
        try expectSameAs(&want, &two_op);
        try expectAndIsCompact(&two_op);

        // The operands are untouched by the two-operand form.
        try expectSameAs(&ra, &a);
        try expectSameAs(&rb, &b);
    }
}

/// And's postcondition: the buffer holds one container per key, in key order,
/// and none of them is empty — except key 0's, which init always creates.
fn expectAndIsCompact(bm: *const Bitmap) !void {
    const ks = bm.keys();
    var off = ks.size();
    var i: usize = 0;
    while (off < bm.data.len) : (i += 1) {
        try testing.expect(i < ks.numKeys());
        try testing.expectEqual(off, ks.val(i)); // no container without a key
        const c = bm.getContainer(off);
        if (i > 0) try testing.expect(container.getCardinality(c) > 0);
        off += container.size(c);
    }
    try testing.expectEqual(ks.numKeys(), i); // no key without a container
}

test "And sizes each result container to the result" {
    // Both operands hold a bitmap container under key 0, so the kernel that
    // runs is bitmap ∩ bitmap and only the overlap decides the result's shape.
    var a = try Bitmap.init(testing.allocator);
    defer a.deinit();
    var i: u64 = 0;
    while (i < 5000) : (i += 1) _ = try a.set(i);
    try testing.expectEqual(container.Type.bitmap, containerTypeOf(&a, 0));

    // 4999 - 2957 + 1 = 2043 values, the most an array container can hold.
    var small = try Bitmap.init(testing.allocator);
    defer small.deinit();
    i = 2957;
    while (i < 7957) : (i += 1) _ = try small.set(i);
    try testing.expectEqual(container.Type.bitmap, containerTypeOf(&small, 0));

    var got = try Bitmap.And(testing.allocator, &a, &small);
    defer got.deinit();
    try testing.expectEqual(@as(u64, 2043), got.getCardinality());
    try testing.expectEqual(container.Type.array, containerTypeOf(&got, 0));
    try testing.expectEqual(@as(u16, 2048), container.size(got.getContainer(got.keys().val(0))));
    try testing.expectEqual(@as(?u64, 2957), got.minimum());
    try testing.expectEqual(@as(?u64, 4999), got.maximum());
    try checkInvariants(&got);
    try expectAndIsCompact(&got);

    // One value more and no array container fits, so the result stays a bitmap.
    var big = try Bitmap.init(testing.allocator);
    defer big.deinit();
    i = 2956;
    while (i < 7956) : (i += 1) _ = try big.set(i);

    var got2 = try Bitmap.And(testing.allocator, &a, &big);
    defer got2.deinit();
    try testing.expectEqual(@as(u64, 2044), got2.getCardinality());
    try testing.expectEqual(container.Type.bitmap, containerTypeOf(&got2, 0));
    try checkInvariants(&got2);
    try expectAndIsCompact(&got2);

    // A small array result is sized for itself, not for either operand.
    var sparse = try testBitmap(&.{ 3, 4998, 4999, 1 << 40 });
    defer sparse.deinit();
    var got3 = try Bitmap.And(testing.allocator, &a, &sparse);
    defer got3.deinit();
    try testing.expectEqual(@as(u64, 3), got3.getCardinality());
    try testing.expectEqual(container.min_size, container.size(got3.getContainer(got3.keys().val(0))));
    try testing.expectEqual(@as(usize, 1), got3.keys().numKeys()); // key 1<<40 dropped
    try checkInvariants(&got3);
    try expectAndIsCompact(&got3);
}

test "And of disjoint bitmaps leaves only key 0" {
    // Shared keys whose values miss each other, plus keys held by one side only.
    var a = try testBitmap(&.{ 1, 3, (1 << 16) | 7, 1 << 32 });
    defer a.deinit();
    var b = try testBitmap(&.{ 2, 4, (1 << 16) | 8, 3 << 32 });
    defer b.deinit();

    var got = try Bitmap.And(testing.allocator, &a, &b);
    defer got.deinit();

    try testing.expect(got.isEmpty());
    try testing.expectEqual(@as(usize, 1), got.keys().numKeys());
    // Key 0's container from init is the only one in the buffer; nothing else
    // was appended and nothing had to be compacted away.
    try testing.expectEqual(got.keys().size() + container.min_size, got.data.len);
    try checkInvariants(&got);
    try expectAndIsCompact(&got);
}

test "And result round trips through a buffer bit identically" {
    // A result with an array container, a bitmap container and a dropped key.
    var a = try Bitmap.init(testing.allocator);
    defer a.deinit();
    var b = try Bitmap.init(testing.allocator);
    defer b.deinit();
    var i: u64 = 0;
    while (i < 5000) : (i += 1) {
        _ = try a.set(i);
        _ = try b.set(i + 2);
    }
    for ([_]u64{ 1 << 32, (1 << 32) + 9, 1 << 48 }) |v| {
        _ = try a.set(v);
        _ = try b.set(v);
    }
    _ = try a.set(7 << 32); // no counterpart in b
    _ = try b.set(9 << 32); // no counterpart in a

    var got = try Bitmap.And(testing.allocator, &a, &b);
    defer got.deinit();
    try testing.expectEqual(container.Type.bitmap, containerTypeOf(&got, 0));
    try testing.expectEqual(container.Type.array, containerTypeOf(&got, 1 << 32));

    const buf = try got.toBufferCopy(testing.allocator);
    defer testing.allocator.free(buf);
    var reopened = try Bitmap.fromBuffer(testing.allocator, buf);
    defer reopened.deinit();

    try testing.expectEqualSlices(u16, got.data, reopened.data);
    try testing.expectEqual(got.getCardinality(), reopened.getCardinality());
    try checkInvariants(&reopened);

    const want = try got.toArray(testing.allocator);
    defer testing.allocator.free(want);
    const have = try reopened.toArray(testing.allocator);
    defer testing.allocator.free(have);
    try testing.expectEqualSlices(u64, want, have);
}

test "andNotInPlace against a reference set" {
    var prng = std.Random.DefaultPrng.init(0xBEEF);
    const rnd = prng.random();

    var round: usize = 0;
    while (round < 8) : (round += 1) {
        var av: [1500]u64 = undefined;
        var bv: [1500]u64 = undefined;
        randomValues(rnd, &av);
        randomValues(rnd, &bv);

        var a = try testBitmap(&av);
        defer a.deinit();
        var b = try testBitmap(&bv);
        defer b.deinit();
        var ra = try testRefSet(&av);
        defer ra.deinit(testing.allocator);
        var rb = try testRefSet(&bv);
        defer rb.deinit(testing.allocator);

        var want = try refAndNot(&ra, &rb);
        defer want.deinit(testing.allocator);

        var got = try a.clone();
        defer got.deinit();
        got.andNotInPlace(&b);
        try expectSameAs(&want, &got);

        got.cleanup();
        try expectSameAs(&want, &got);
        try expectSameAs(&rb, &b);
    }
}

test "in-place ops on dense bitmap containers keep exact cardinality" {
    // Regression: @popCount on a u64 vector yields u7 lanes, and an unwidened
    // @reduce summed them modulo 128, so dense chunks wrapped (2043 -> 123).
    // Random-value tests never hit it; consecutive ranges do.
    var av: [5000]u64 = undefined;
    for (&av, 0..) |*v, i| v.* = i;
    var bv: [5000]u64 = undefined;
    for (&bv, 0..) |*v, i| v.* = 2957 + i;

    var a = try testBitmap(&av);
    defer a.deinit();
    var b = try testBitmap(&bv);
    defer b.deinit();

    var got_and = try a.clone();
    defer got_and.deinit();
    got_and.andInPlace(&b);
    try testing.expectEqual(@as(u64, 2043), got_and.getCardinality());

    var got_andnot = try a.clone();
    defer got_andnot.deinit();
    got_andnot.andNotInPlace(&b);
    try testing.expectEqual(@as(u64, 2957), got_andnot.getCardinality());

    var got_or = try a.clone();
    defer got_or.deinit();
    try got_or.orInPlace(&b);
    try testing.expectEqual(@as(u64, 7957), got_or.getCardinality());
}

test "orInPlace and Or against a reference set" {
    var prng = std.Random.DefaultPrng.init(0xF00D);
    const rnd = prng.random();

    var round: usize = 0;
    while (round < 8) : (round += 1) {
        var av: [1500]u64 = undefined;
        var bv: [1500]u64 = undefined;
        randomValues(rnd, &av);
        randomValues(rnd, &bv);

        var a = try testBitmap(&av);
        defer a.deinit();
        var b = try testBitmap(&bv);
        defer b.deinit();
        var ra = try testRefSet(&av);
        defer ra.deinit(testing.allocator);
        var rb = try testRefSet(&bv);
        defer rb.deinit(testing.allocator);

        var want = try refOr(&ra, &rb);
        defer want.deinit(testing.allocator);

        var in_place = try a.clone();
        defer in_place.deinit();
        try in_place.orInPlace(&b);
        try expectSameAs(&want, &in_place);

        var two_op = try Bitmap.Or(testing.allocator, &a, &b);
        defer two_op.deinit();
        try expectSameAs(&want, &two_op);

        // Unioning the other way round gives the same set.
        var flipped = try b.clone();
        defer flipped.deinit();
        try flipped.orInPlace(&a);
        try expectSameAs(&want, &flipped);

        try expectSameAs(&ra, &a);
        try expectSameAs(&rb, &b);
    }
}

/// The three fused counts must agree with the operations they stand in for,
/// built the long way round.
fn expectFusedAgree(a: *const Bitmap, b: *const Bitmap) !void {
    var and_res = try Bitmap.And(testing.allocator, a, b);
    defer and_res.deinit();
    try testing.expectEqual(and_res.getCardinality(), a.andCardinality(b));

    var or_res = try Bitmap.fastOr(testing.allocator, &.{ a, b });
    defer or_res.deinit();
    try testing.expectEqual(or_res.getCardinality(), a.orCardinality(b));

    var diff = try a.clone();
    defer diff.deinit();
    diff.andNotInPlace(b);
    try testing.expectEqual(diff.getCardinality(), a.andNotCardinality(b));
}

test "fused cardinalities agree with the materialized results" {
    var prng = std.Random.DefaultPrng.init(0xCA4D);
    const rnd = prng.random();

    var round: usize = 0;
    while (round < 8) : (round += 1) {
        var av: [1500]u64 = undefined;
        var bv: [1500]u64 = undefined;
        randomValues(rnd, &av);
        randomValues(rnd, &bv);

        var a = try testBitmap(&av);
        defer a.deinit();
        var b = try testBitmap(&bv);
        defer b.deinit();

        try expectFusedAgree(&a, &b);
        // Neither is symmetric in general; the difference certainly is not.
        try expectFusedAgree(&b, &a);
    }
}

test "fused cardinalities on dense consecutive ranges" {
    // The u7-popcount shape: overlapping runs long enough that a bitmap∩bitmap
    // chunk is fully set, which an unwidened @reduce would wrap at 128.
    var av: [5000]u64 = undefined;
    for (&av, 0..) |*v, i| v.* = i;
    var bv: [5000]u64 = undefined;
    for (&bv, 0..) |*v, i| v.* = 2957 + i;

    var a = try testBitmap(&av);
    defer a.deinit();
    var b = try testBitmap(&bv);
    defer b.deinit();

    try testing.expectEqual(@as(u64, 2043), a.andCardinality(&b));
    try testing.expectEqual(@as(u64, 7957), a.orCardinality(&b));
    try testing.expectEqual(@as(u64, 2957), a.andNotCardinality(&b));
    try testing.expectEqual(@as(u64, 2957), b.andNotCardinality(&a));
    try expectFusedAgree(&a, &b);

    // Identical dense ranges: every chunk of the intersection is full.
    var c = try testBitmap(&av);
    defer c.deinit();
    try testing.expectEqual(@as(u64, 5000), a.andCardinality(&c));
    try testing.expectEqual(@as(u64, 5000), a.orCardinality(&c));
    try testing.expectEqual(@as(u64, 0), a.andNotCardinality(&c));
}

test "fused cardinalities on empty, self and disjoint operands" {
    const vals = [_]u64{ 0, 7, 1 << 16, (1 << 32) | 5, std.math.maxInt(u64) };
    var full = try testBitmap(&vals);
    defer full.deinit();
    var empty = try Bitmap.init(testing.allocator);
    defer empty.deinit();

    // Against the empty bitmap, both ways round.
    try testing.expectEqual(@as(u64, 0), full.andCardinality(&empty));
    try testing.expectEqual(@as(u64, vals.len), full.orCardinality(&empty));
    try testing.expectEqual(@as(u64, vals.len), full.andNotCardinality(&empty));
    try testing.expectEqual(@as(u64, 0), empty.andCardinality(&full));
    try testing.expectEqual(@as(u64, vals.len), empty.orCardinality(&full));
    try testing.expectEqual(@as(u64, 0), empty.andNotCardinality(&full));
    try testing.expectEqual(@as(u64, 0), empty.orCardinality(&empty));

    // Against itself.
    try testing.expectEqual(@as(u64, vals.len), full.andCardinality(&full));
    try testing.expectEqual(@as(u64, vals.len), full.orCardinality(&full));
    try testing.expectEqual(@as(u64, 0), full.andNotCardinality(&full));

    // Keys that miss each other entirely, and keys that meet but whose values
    // do not — the two ways an intersection can come out empty.
    var other = try testBitmap(&.{ 8, (1 << 40) | 3 });
    defer other.deinit();
    try testing.expectEqual(@as(u64, 0), full.andCardinality(&other));
    try testing.expectEqual(@as(u64, vals.len + 2), full.orCardinality(&other));
    try testing.expectEqual(@as(u64, vals.len), full.andNotCardinality(&other));
    try expectFusedAgree(&full, &other);
    try expectFusedAgree(&other, &full);

    // Emptied containers still carry keys until cleanup; they must count as 0.
    var emptied = try full.clone();
    defer emptied.deinit();
    emptied.andInPlace(&other);
    try testing.expect(emptied.keys().numKeys() > 1);
    try testing.expectEqual(@as(u64, 0), emptied.andCardinality(&full));
    try testing.expectEqual(@as(u64, vals.len), emptied.orCardinality(&full));
    try testing.expectEqual(@as(u64, 0), emptied.andNotCardinality(&full));
}

test "fused cardinalities across every container type pairing" {
    // Dense key 0 (bitmap container) against sparse key 0 (array container), so
    // all four kernels behind containerAndCardinality run.
    var dense = try Bitmap.init(testing.allocator);
    defer dense.deinit();
    var i: u64 = 0;
    while (i < 4000) : (i += 1) _ = try dense.set(i);
    _ = try dense.set(1 << 32);

    var sparse = try testBitmap(&.{ 5, 4000, 4001, 1 << 32 });
    defer sparse.deinit();

    // array ∩ bitmap and bitmap ∩ array, one per argument order.
    try testing.expectEqual(@as(u64, 2), dense.andCardinality(&sparse));
    try testing.expectEqual(@as(u64, 2), sparse.andCardinality(&dense));
    try expectFusedAgree(&dense, &sparse);
    try expectFusedAgree(&sparse, &dense);

    // array ∩ array past the 64x skew, where the counting kernel gallops.
    var large = try Bitmap.init(testing.allocator);
    defer large.deinit();
    i = 0;
    while (i < 1000) : (i += 1) _ = try large.set(i * 3);
    var small = try testBitmap(&.{ 0, 1, 3, 2997 });
    defer small.deinit();

    try testing.expectEqual(@as(u64, 3), large.andCardinality(&small));
    try testing.expectEqual(@as(u64, 3), small.andCardinality(&large));
    try expectFusedAgree(&large, &small);
    try expectFusedAgree(&small, &large);

    // bitmap ∩ bitmap.
    var dense2 = try Bitmap.init(testing.allocator);
    defer dense2.deinit();
    i = 2000;
    while (i < 6000) : (i += 1) _ = try dense2.set(i);
    try testing.expectEqual(@as(u64, 2000), dense.andCardinality(&dense2));
    try expectFusedAgree(&dense, &dense2);
}

test "set operations on empty bitmaps" {
    const vals = [_]u64{ 0, 7, 1 << 16, (1 << 32) | 5, std.math.maxInt(u64) };

    var full = try testBitmap(&vals);
    defer full.deinit();
    var ref = try testRefSet(&vals);
    defer ref.deinit(testing.allocator);
    var none = RefSet.empty;
    defer none.deinit(testing.allocator);

    var empty = try Bitmap.init(testing.allocator);
    defer empty.deinit();

    // x ∩ ∅ = ∅, ∅ ∩ x = ∅
    var a = try full.clone();
    defer a.deinit();
    a.andInPlace(&empty);
    try expectSameAs(&none, &a);

    var b = try empty.clone();
    defer b.deinit();
    b.andInPlace(&full);
    try expectSameAs(&none, &b);

    // x \ ∅ = x, ∅ \ x = ∅
    var c = try full.clone();
    defer c.deinit();
    c.andNotInPlace(&empty);
    try expectSameAs(&ref, &c);

    var d = try empty.clone();
    defer d.deinit();
    d.andNotInPlace(&full);
    try expectSameAs(&none, &d);

    // x ∪ ∅ = x, ∅ ∪ x = x
    var e = try full.clone();
    defer e.deinit();
    try e.orInPlace(&empty);
    try expectSameAs(&ref, &e);

    var f = try empty.clone();
    defer f.deinit();
    try f.orInPlace(&full);
    try expectSameAs(&ref, &f);

    var g = try Bitmap.And(testing.allocator, &full, &empty);
    defer g.deinit();
    try expectSameAs(&none, &g);

    var h = try Bitmap.Or(testing.allocator, &empty, &empty);
    defer h.deinit();
    try expectSameAs(&none, &h);

    // Cleaning up a bitmap that is entirely empty keeps key 0 and stays valid.
    var i = try empty.clone();
    defer i.deinit();
    i.cleanup();
    try expectSameAs(&none, &i);
    try testing.expectEqual(@as(usize, 1), i.keys().numKeys());
}

test "set operations against self" {
    var prng = std.Random.DefaultPrng.init(0x5E1F);
    const rnd = prng.random();
    var vals: [2000]u64 = undefined;
    randomValues(rnd, &vals);

    var bm = try testBitmap(&vals);
    defer bm.deinit();
    var ref = try testRefSet(&vals);
    defer ref.deinit(testing.allocator);
    var none = RefSet.empty;
    defer none.deinit(testing.allocator);

    // x ∩ x = x, in place and against a copy of itself.
    var a = try bm.clone();
    defer a.deinit();
    a.andInPlace(&a);
    try expectSameAs(&ref, &a);
    a.andInPlace(&bm);
    try expectSameAs(&ref, &a);

    // x \ x = ∅
    var b = try bm.clone();
    defer b.deinit();
    b.andNotInPlace(&b);
    try expectSameAs(&none, &b);

    // x ∪ x = x. orInPlace can grow the buffer, so it needs a separate copy.
    var c = try bm.clone();
    defer c.deinit();
    try c.orInPlace(&bm);
    try expectSameAs(&ref, &c);

    var d = try Bitmap.And(testing.allocator, &bm, &bm);
    defer d.deinit();
    try expectSameAs(&ref, &d);

    var e = try Bitmap.Or(testing.allocator, &bm, &bm);
    defer e.deinit();
    try expectSameAs(&ref, &e);
}

test "andInPlace on containers that disagree on type" {
    // A dense key 0 (bitmap container) against a sparse key 0 (array), and the
    // reverse, so both mixed-type kernels run at the bitmap level.
    var dense = try Bitmap.init(testing.allocator);
    defer dense.deinit();
    var i: u64 = 0;
    while (i < 4000) : (i += 1) _ = try dense.set(i);
    _ = try dense.set(1 << 32);

    var sparse = try testBitmap(&.{ 5, 4000, 4001, 1 << 32 });
    defer sparse.deinit();

    var a = try dense.clone();
    defer a.deinit();
    a.andInPlace(&sparse);
    try testing.expectEqual(@as(u64, 2), a.getCardinality());
    try testing.expect(a.contains(5) and a.contains(1 << 32));
    try testing.expectEqual(container.Type.bitmap, containerTypeOf(&a, 0)); // never demoted
    try checkInvariants(&a);

    var b = try sparse.clone();
    defer b.deinit();
    b.andInPlace(&dense);
    try testing.expectEqual(@as(u64, 2), b.getCardinality());
    try testing.expect(b.contains(5) and b.contains(1 << 32));
    try testing.expectEqual(container.Type.array, containerTypeOf(&b, 0));
    try checkInvariants(&b);
}

test "orInPlace grows array containers through every size step" {
    // Key 0 starts as a min_size array and has to walk every doubling up to
    // 2048 and then convert to a bitmap as the unions get bigger.
    var dst = try testBitmap(&.{1});
    defer dst.deinit();
    var ref = try testRefSet(&.{1});
    defer ref.deinit(testing.allocator);

    var step: u64 = 0;
    while (step < 12) : (step += 1) {
        var vals: [400]u64 = undefined;
        for (&vals, 0..) |*v, k| v.* = step * 400 + k * 3;

        var src = try testBitmap(&vals);
        defer src.deinit();
        for (vals) |v| try ref.put(testing.allocator, v, {});

        try dst.orInPlace(&src);
        try expectSameAs(&ref, &dst);
    }
    try testing.expectEqual(container.Type.bitmap, containerTypeOf(&dst, 0));
}

test "fastOr matches folded orInPlace and a reference union" {
    var prng = std.Random.DefaultPrng.init(0x0FA5);
    const rnd = prng.random();

    const num = 60;
    var list: [num]Bitmap = undefined;
    var ptrs: [num]*const Bitmap = undefined;
    var ref = RefSet.empty;
    defer ref.deinit(testing.allocator);

    var made: usize = 0;
    defer for (list[0..made]) |*bm| bm.deinit();
    while (made < num) : (made += 1) {
        var vals: [200]u64 = undefined;
        randomValues(rnd, &vals);
        for (vals) |v| try ref.put(testing.allocator, v, {});
        list[made] = try testBitmap(&vals);
        ptrs[made] = &list[made];
    }

    var fast = try Bitmap.fastOr(testing.allocator, &ptrs);
    defer fast.deinit();
    try expectSameAs(&ref, &fast);

    var folded = try Bitmap.init(testing.allocator);
    defer folded.deinit();
    for (list[0..made]) |*bm| try folded.orInPlace(bm);
    try expectSameAs(&ref, &folded);

    const a = try fast.toArray(testing.allocator);
    defer testing.allocator.free(a);
    const b = try folded.toArray(testing.allocator);
    defer testing.allocator.free(b);
    try testing.expectEqualSlices(u64, b, a);
}

test "fastOr edge cases: none, one, disjoint keys, one shared key" {
    var empty = try Bitmap.fastOr(testing.allocator, &.{});
    defer empty.deinit();
    try testing.expect(empty.isEmpty());
    try checkInvariants(&empty);

    const vals = [_]u64{ 0, 3, 1 << 16, 1 << 48 };
    var one = try testBitmap(&vals);
    defer one.deinit();
    var ref = try testRefSet(&vals);
    defer ref.deinit(testing.allocator);

    var single = try Bitmap.fastOr(testing.allocator, &.{&one});
    defer single.deinit();
    try expectSameAs(&ref, &single);
    // The result must be independent of the input.
    _ = try single.set(1 << 40);
    try testing.expect(!one.contains(1 << 40));

    // Inputs that share no key at all.
    var disjoint: [8]Bitmap = undefined;
    var dptrs: [8]*const Bitmap = undefined;
    var dref = RefSet.empty;
    defer dref.deinit(testing.allocator);
    for (&disjoint, 0..) |*bm, i| {
        const v = (@as(u64, i + 1) << 32) | (i * 7);
        bm.* = try testBitmap(&.{ v, v + 1 });
        dptrs[i] = bm;
        try dref.put(testing.allocator, v, {});
        try dref.put(testing.allocator, v + 1, {});
    }
    defer for (&disjoint) |*bm| bm.deinit();

    var d = try Bitmap.fastOr(testing.allocator, &dptrs);
    defer d.deinit();
    try expectSameAs(&dref, &d);

    // Inputs that all pile into one key, enough of them to need a bitmap.
    var shared: [40]Bitmap = undefined;
    var sptrs: [40]*const Bitmap = undefined;
    var sref = RefSet.empty;
    defer sref.deinit(testing.allocator);
    for (&shared, 0..) |*bm, i| {
        var vals_i: [200]u64 = undefined;
        for (&vals_i, 0..) |*v, k| v.* = (1 << 48) | (i * 200 + k);
        bm.* = try testBitmap(&vals_i);
        sptrs[i] = bm;
        for (vals_i) |v| try sref.put(testing.allocator, v, {});
    }
    defer for (&shared) |*bm| bm.deinit();

    var s = try Bitmap.fastOr(testing.allocator, &sptrs);
    defer s.deinit();
    try expectSameAs(&sref, &s);
    try testing.expectEqual(container.Type.bitmap, containerTypeOf(&s, 1 << 48));
}

test "fromSortedList matches a set loop and round trips" {
    var prng = std.Random.DefaultPrng.init(0x5027);
    const rnd = prng.random();

    var vals: [6000]u64 = undefined;
    randomValues(rnd, &vals);
    // A dense run so at least one key needs a bitmap container, and duplicates
    // so the builder has to skip them.
    for (vals[0..5000], 0..) |*v, i| v.* = (1 << 32) | (i / 2);
    std.mem.sort(u64, &vals, {}, std.sort.asc(u64));

    var built = try Bitmap.fromSortedList(testing.allocator, &vals);
    defer built.deinit();

    var ref = try testRefSet(&vals);
    defer ref.deinit(testing.allocator);
    try expectSameAs(&ref, &built);
    try testing.expectEqual(container.Type.bitmap, containerTypeOf(&built, 1 << 32));

    var looped = try testBitmap(&vals);
    defer looped.deinit();
    const a = try built.toArray(testing.allocator);
    defer testing.allocator.free(a);
    const b = try looped.toArray(testing.allocator);
    defer testing.allocator.free(b);
    try testing.expectEqualSlices(u64, b, a);

    const buf = try built.toBufferCopy(testing.allocator);
    defer testing.allocator.free(buf);
    var reopened = try Bitmap.fromBuffer(testing.allocator, buf);
    defer reopened.deinit();
    try testing.expectEqualSlices(u16, built.data, reopened.data);
    try expectSameAs(&ref, &reopened);

    // Degenerate inputs.
    var none = try Bitmap.fromSortedList(testing.allocator, &.{});
    defer none.deinit();
    try testing.expect(none.isEmpty());
    try checkInvariants(&none);

    var one = try Bitmap.fromSortedList(testing.allocator, &.{std.math.maxInt(u64)});
    defer one.deinit();
    try testing.expectEqual(@as(u64, 1), one.getCardinality());
    try testing.expect(one.contains(std.math.maxInt(u64)));
    try checkInvariants(&one);
}

test "cleanup compacts the buffer and keeps key 0" {
    var vals: [3000]u64 = undefined;
    for (&vals, 0..) |*v, i| v.* = (@as(u64, i % 30) << 32) | (i * 5);

    var bm = try testBitmap(&vals);
    defer bm.deinit();
    const keys_before = bm.keys().numKeys();
    const len_before = bm.data.len;

    // Intersect with a bitmap holding one value under one key: every other
    // container is emptied, and so is key 0's.
    var keep = try testBitmap(&.{(@as(u64, 7) << 32) | 35});
    defer keep.deinit();

    bm.andInPlace(&keep);
    try testing.expectEqual(@as(u64, 1), bm.getCardinality());
    try testing.expectEqual(keys_before, bm.keys().numKeys()); // nothing removed yet
    try testing.expectEqual(len_before, bm.data.len);

    bm.cleanup();
    try testing.expect(bm.data.len < len_before);
    try testing.expectEqual(@as(usize, 2), bm.keys().numKeys()); // key 0 and key 7
    try testing.expectEqual(@as(u64, 0), bm.keys().key(0));
    try testing.expectEqual(@as(u64, 1), bm.getCardinality());
    try testing.expect(bm.contains((@as(u64, 7) << 32) | 35));
    try checkInvariants(&bm);

    // A second cleanup is a no-op, and the bitmap still takes new values.
    const len_after = bm.data.len;
    bm.cleanup();
    try testing.expectEqual(len_after, bm.data.len);
    try testing.expect(try bm.set(1 << 60));
    try testing.expect(try bm.set(3));
    try testing.expectEqual(@as(u64, 3), bm.getCardinality());
    try checkInvariants(&bm);

    // The compacted buffer is still a valid serialized bitmap.
    const buf = try bm.toBufferCopy(testing.allocator);
    defer testing.allocator.free(buf);
    var reopened = try Bitmap.fromBuffer(testing.allocator, buf);
    defer reopened.deinit();
    try testing.expectEqual(@as(u64, 3), reopened.getCardinality());
    try checkInvariants(&reopened);
}

test "cleanup removes neighbouring empty containers as one hole" {
    var bm = try Bitmap.init(testing.allocator);
    defer bm.deinit();
    var k: u64 = 0;
    while (k < 10) : (k += 1) {
        var j: u64 = 0;
        while (j < 100) : (j += 1) _ = try bm.set((k << 16) | j);
    }
    const len_before = bm.data.len;

    // Empty keys 1..8, leaving live containers only at the two ends.
    k = 1;
    while (k < 9) : (k += 1) {
        var j: u64 = 0;
        while (j < 100) : (j += 1) _ = bm.remove((k << 16) | j);
    }
    bm.cleanup();

    try testing.expectEqual(@as(usize, 2), bm.keys().numKeys());
    try testing.expectEqual(@as(u64, 200), bm.getCardinality());
    try testing.expect(bm.data.len < len_before);
    try testing.expect(bm.contains(0) and bm.contains(9 << 16));
    try testing.expect(!bm.contains(5 << 16));
    try checkInvariants(&bm);
}

test "a cleaned up bitmap can grow again" {
    var bm = try Bitmap.init(testing.allocator);
    defer bm.deinit();

    // Enough keys to grow the node several times, then remove almost all of
    // them, so cleanup has to shrink the node by many pairs at once.
    var k: u64 = 0;
    while (k < 500) : (k += 1) _ = try bm.set(k << 16);
    k = 1;
    while (k < 500) : (k += 1) _ = bm.remove(k << 16);

    bm.cleanup();
    try testing.expectEqual(@as(usize, 1), bm.keys().numKeys());
    try testing.expectEqual(@as(u64, 1), bm.getCardinality());
    try checkInvariants(&bm);

    // The shrunken node must still take new keys, growing as it did before.
    var ref = try testRefSet(&.{0});
    defer ref.deinit(testing.allocator);
    k = 1;
    while (k < 800) : (k += 1) {
        const v = (k << 32) | (k % 97);
        _ = try bm.set(v);
        try ref.put(testing.allocator, v, {});
    }
    try expectSameAs(&ref, &bm);
}

test "fromSortedList pre-sizes the node for many keys" {
    const num_keys = 5000;
    var vals: [num_keys]u64 = undefined;
    for (&vals, 0..) |*v, i| v.* = (@as(u64, i) << 32) | (i % 1000);

    var bm = try Bitmap.fromSortedList(testing.allocator, &vals);
    defer bm.deinit();

    var ref = try testRefSet(&vals);
    defer ref.deinit(testing.allocator);
    try expectSameAs(&ref, &bm);
    try testing.expectEqual(@as(usize, num_keys), bm.keys().numKeys());
    // Every container was written at its final size, so nothing had to expand.
    try testing.expectEqual(@as(?u64, vals[0]), bm.minimum());
    try testing.expectEqual(@as(?u64, vals[num_keys - 1]), bm.maximum());
}

test "fastOr over inputs that hold nothing" {
    var a = try Bitmap.init(testing.allocator);
    defer a.deinit();
    var b = try Bitmap.init(testing.allocator);
    defer b.deinit();
    _ = try b.set(9);
    try testing.expect(b.remove(9)); // an empty container that still has a key

    var res = try Bitmap.fastOr(testing.allocator, &.{ &a, &b });
    defer res.deinit();
    try testing.expect(res.isEmpty());
    try testing.expectEqual(@as(usize, 1), res.keys().numKeys());
    try checkInvariants(&res);
    try testing.expect(try res.set(1 << 33));
}

test "chains of operations keep agreeing with a reference set" {
    var prng = std.Random.DefaultPrng.init(0xC0DEC0DE);
    const rnd = prng.random();

    var round: usize = 0;
    while (round < 40) : (round += 1) {
        var av: [800]u64 = undefined;
        var bv: [800]u64 = undefined;
        randomValues(rnd, &av);
        randomValues(rnd, &bv);

        var bm = try testBitmap(&av);
        defer bm.deinit();
        var ref = try testRefSet(&av);
        defer ref.deinit(testing.allocator);

        var other = try testBitmap(&bv);
        defer other.deinit();
        var oref = try testRefSet(&bv);
        defer oref.deinit(testing.allocator);

        var step: usize = 0;
        while (step < 6) : (step += 1) {
            const want = switch (rnd.uintLessThan(u8, 3)) {
                0 => blk: {
                    bm.andInPlace(&other);
                    break :blk try refAnd(&ref, &oref);
                },
                1 => blk: {
                    bm.andNotInPlace(&other);
                    break :blk try refAndNot(&ref, &oref);
                },
                else => blk: {
                    try bm.orInPlace(&other);
                    break :blk try refOr(&ref, &oref);
                },
            };
            ref.deinit(testing.allocator);
            ref = want;

            if (rnd.boolean()) bm.cleanup();
            try expectSameAs(&ref, &bm);

            // A serialization round trip in the middle must change nothing.
            if (rnd.boolean()) {
                const buf = try bm.toBufferCopy(testing.allocator);
                defer testing.allocator.free(buf);
                const reopened = try Bitmap.fromBufferCopy(testing.allocator, buf);
                bm.deinit();
                bm = reopened;
                try expectSameAs(&ref, &bm);
            }

            // Point operations must still behave on the reshaped buffer.
            var extra: [40]u64 = undefined;
            randomValues(rnd, &extra);
            for (extra) |v| {
                if (rnd.boolean()) {
                    _ = try bm.set(v);
                    try ref.put(testing.allocator, v, {});
                } else {
                    _ = bm.remove(v);
                    _ = ref.remove(v);
                }
            }
            try expectSameAs(&ref, &bm);
        }
    }
}

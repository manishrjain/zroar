//! The keys node: the front of a bitmap's flat buffer, mapping each 48-bit
//! key to the offset of its container.
//!
//! The node is two parallel arrays behind a two-u64 header:
//!
//! | u64 index      | meaning                                              |
//! |----------------|------------------------------------------------------|
//! | 0              | node size in **u16** units (always a multiple of 4)   |
//! | 1              | capacity in the high 32 bits, key count in the low 32 |
//! | 2 .. 2+cap     | `KeyBox`: u64 keys, sorted ascending                  |
//! | 2+cap ..       | `OffsetBox`: u32 container offsets, one per key       |
//!
//! Keys and offsets are parallel arrays rather than interleaved pairs because
//! a lookup reads only keys. Interleaving puts an offset on every cache line
//! the search touches and makes a vector load deinterleave before it can
//! compare; over 153 keys, splitting them takes a lookup from 26 ns to 13 ns.
//!
//! Ported from sroar's keys.go, which interleaves and uses u64 for both.

const std = @import("std");
const assert = std.debug.assert;

/// The high 48 bits of a value select its container; the low 16 select the bit.
pub const key_mask: u64 = 0xFFFF_FFFF_FFFF_0000;

pub const index_node_size: usize = 0;
pub const index_counts: usize = 1;
pub const index_node_start: usize = 2;

/// Capacity always moves in steps of this many keys. A key costs 8 bytes and
/// its offset 4, so a single key would swing the node's size off the 8-byte
/// boundary that the container after it needs; two keys cost 24 bytes and
/// keep it.
pub const cap_step: usize = 2;

/// `KeyBox.search` stops bisecting once the window is this small and scans
/// what is left.
///
/// Bisecting is a chain of dependent loads: each address depends on the
/// previous comparison, so a CPU that cannot predict the path stalls at
/// every step. A scan is the opposite shape: branch-free, every load
/// independent, fully pipelined. The right cutoff is where one more bisect
/// step (~3-4 ns) stops paying for the halved scan it buys, measured over
/// random probes on this layout as:
///
/// | window | 128 keys | 153 keys | 256 keys | 4096 keys |
/// |--------|----------|----------|----------|-----------|
/// | 64     |  9.2 ns  | 11.2 ns  | 13.0 ns  |  25.6 ns  |
/// | 128    |  8.2 ns  |  9.8 ns  | 13.6 ns  |  29.5 ns  |
/// | 256    |  8.2 ns  | 10.4 ns  | 16.0 ns  |  32.0 ns  |
///
/// 64 rather than 128 because zroar cannot assume the target's vector width.
/// Rebuilt for baseline x86-64, where `@Vector(8, u64)` lowers to four SSE2
/// operations instead of two AVX2 ones, a 128-key window costs 26.9 ns at 153
/// keys against 17.9 for a 64-key one — and against 25.2 for not scanning at
/// all. A 64-key window is the only setting that wins on both.
pub const scan_max_keys: usize = 64;

/// Offsets are u32, so no buffer may exceed this many u16s (8 GiB). Every
/// posting list is orders of magnitude below it; `OffsetBox.setAt` asserts
/// rather than letting a truncated offset point at nothing.
pub const max_buffer_u16: usize = std.math.maxInt(u32);

/// Node size in u16 units for a node with room for `cap` keys.
pub fn nodeSizeFor(cap: usize) usize {
    assert(cap % cap_step == 0);
    // Two u64s of header, one u64 per key, one u32 per offset.
    return 4 * (index_node_start + cap + cap / 2);
}

/// The keys in use: sorted, searchable, `len` of the `all.len` slots filled.
pub const KeyBox = struct {
    all: []u64,
    len: usize,

    pub fn used(self: KeyBox) []u64 {
        return self.all[0..self.len];
    }

    pub fn at(self: KeyBox, i: usize) u64 {
        assert(i < self.len);
        return self.all[i];
    }

    pub fn setAt(self: KeyBox, i: usize, k: u64) void {
        assert(i < self.all.len);
        assert(k & key_mask == k);
        self.all[i] = k;
    }

    /// Index of the smallest key >= k, or `len` if there is none.
    ///
    /// Bisect only until the window is small enough to scan, then scan it. A
    /// node that already fits the window never enters the loop, so this is one
    /// function rather than two paths.
    pub fn search(self: KeyBox, k: u64) usize {
        const ks = self.used();
        var lo: usize = 0;
        var hi: usize = ks.len;
        while (hi - lo > scan_max_keys) {
            const mid = lo + (hi - lo) / 2;
            if (ks[mid] < k) lo = mid + 1 else hi = mid;
        }
        // Every key below lo is < k and every key from hi up is >= k, so the
        // answer is lo plus however many of the remaining window are below k.
        return lo + scan(ks[lo..hi], k);
    }

    /// Counts the keys below `k`, which for a sorted array is the index of the
    /// first key >= k. Contiguous keys make the vector step a plain load,
    /// compare and popcount with no shuffle; a node shorter than one vector
    /// falls straight through to the scalar tail.
    fn scan(ks: []const u64, k: u64) usize {
        const lanes = 8;
        const V = @Vector(lanes, u64);
        const target: V = @splat(k);

        var count: usize = 0;
        var i: usize = 0;
        while (i + lanes <= ks.len) : (i += lanes) {
            const v: V = ks[i..][0..lanes].*;
            const below: u8 = @bitCast(v < target);
            count += @popCount(below);
        }
        while (i < ks.len) : (i += 1) count += @intFromBool(ks[i] < k);
        return count;
    }

    /// Shifts [i, len) one slot right, leaving slot i free. The caller has
    /// checked there is a spare slot to shift into.
    pub fn openAt(self: KeyBox, i: usize) void {
        assert(self.len < self.all.len);
        std.mem.copyBackwards(
            u64,
            self.all[i + 1 .. self.len + 1],
            self.all[i..self.len],
        );
    }
};

/// The container offsets, one per key at the same index.
pub const OffsetBox = struct {
    all: []u32,
    len: usize,

    pub fn used(self: OffsetBox) []u32 {
        return self.all[0..self.len];
    }

    pub fn at(self: OffsetBox, i: usize) usize {
        assert(i < self.len);
        return self.all[i];
    }

    pub fn setAt(self: OffsetBox, i: usize, off: usize) void {
        assert(i < self.all.len);
        assert(off <= max_buffer_u16);
        self.all[i] = @intCast(off);
    }

    pub fn openAt(self: OffsetBox, i: usize) void {
        assert(self.len < self.all.len);
        std.mem.copyBackwards(
            u32,
            self.all[i + 1 .. self.len + 1],
            self.all[i..self.len],
        );
    }

    /// Shifts every offset strictly greater than `beyond` by `by`. The
    /// comparison is strict so the container living at `beyond` itself, whose
    /// own start did not move, is left alone.
    pub fn shiftPast(
        self: OffsetBox,
        beyond: usize,
        by: usize,
        add: bool,
    ) void {
        for (self.used()) |*slot| {
            const off: usize = slot.*;
            if (off <= beyond) continue;
            if (add) {
                assert(off + by <= max_buffer_u16);
                slot.* = @intCast(off + by);
            } else {
                assert(off >= by);
                slot.* = @intCast(off - by);
            }
        }
    }

    /// Adds `by` to every offset, for when the whole container region moved.
    pub fn shiftAll(self: OffsetBox, by: usize, add: bool) void {
        self.shiftPast(0, by, add);
    }
};

/// A borrowed view of the index. Never store one across a call that can
/// grow the buffer: growth reallocates and the view dangles.
pub const Index = struct {
    n: []u64,

    /// Node size in u16 units.
    pub fn size(self: Index) usize {
        return @intCast(self.n[index_node_size]);
    }

    pub fn numKeys(self: Index) usize {
        // Truncate to u32 explicitly: usize is 64 bits here, so truncating
        // straight to usize would keep the capacity in the high half.
        return @as(u32, @truncate(self.n[index_counts]));
    }

    /// Number of keys the node has room for.
    pub fn maxKeys(self: Index) usize {
        return @intCast(self.n[index_counts] >> 32);
    }

    pub fn isFull(self: Index) bool {
        return self.numKeys() == self.maxKeys();
    }

    pub fn keys(self: Index) KeyBox {
        return .{
            .all = self.n[index_node_start..][0..self.maxKeys()],
            .len = self.numKeys(),
        };
    }

    pub fn offsets(self: Index) OffsetBox {
        const cap = self.maxKeys();
        const p: [*]u32 = @ptrCast(self.n.ptr + index_node_start + cap);
        return .{ .all = p[0..cap], .len = self.numKeys() };
    }

    /// Key at index i. Shorthand for `keys().at(i)`, which most callers want.
    pub fn key(self: Index, i: usize) u64 {
        return self.keys().at(i);
    }

    /// Container offset at index i, in u16 units.
    pub fn offset(self: Index, i: usize) usize {
        return self.offsets().at(i);
    }

    pub fn setKeyAt(self: Index, i: usize, k: u64) void {
        self.keys().setAt(i, k);
    }

    pub fn setOffsetAt(self: Index, i: usize, off: usize) void {
        self.offsets().setAt(i, off);
    }

    pub fn setNodeSize(self: Index, sz: usize) void {
        self.n[index_node_size] = sz;
    }

    pub fn setNumKeys(self: Index, num: usize) void {
        assert(num <= self.maxKeys());
        self.n[index_counts] =
            (self.n[index_counts] & 0xFFFF_FFFF_0000_0000) | num;
    }

    /// Declares the node's capacity. The caller owns the node's size header
    /// and must have made room for `nodeSizeFor(cap)` u16s.
    pub fn setMaxKeys(self: Index, cap: usize) void {
        assert(cap % cap_step == 0);
        assert(cap <= std.math.maxInt(u32));
        assert(self.numKeys() <= cap);
        self.n[index_counts] =
            (@as(u64, cap) << 32) | @as(u64, self.numKeys());
    }

    pub fn search(self: Index, k: u64) usize {
        return self.keys().search(k);
    }

    /// The container offset registered for k, or null if k has no container.
    pub fn getOffset(self: Index, k: u64) ?usize {
        const masked = k & key_mask;
        const kb = self.keys();
        const idx = kb.search(masked);
        if (idx >= kb.len or kb.at(idx) != masked) return null;
        return self.offsets().at(idx);
    }

    /// Inserts key k with offset `off`, or updates the offset if k is already
    /// present. Returns true when a new key was added. The caller guarantees
    /// room: the node is grown as soon as it becomes full, so it is never full
    /// on entry.
    pub fn set(self: Index, k: u64, off: usize) bool {
        const kb = self.keys();
        const idx = kb.search(k);
        if (idx < kb.len and kb.at(idx) == k) {
            self.offsets().setAt(idx, off);
            return false;
        }

        assert(!self.isFull());
        if (idx < kb.len) {
            kb.openAt(idx);
            self.offsets().openAt(idx);
        }
        self.setNumKeys(kb.len + 1);
        self.keys().setAt(idx, k);
        self.offsets().setAt(idx, off);
        return true;
    }

    /// Changes how many keys the node has room for. The offsets live directly
    /// after the key capacity, so this moves them: their address is derived
    /// from the capacity, not stored.
    /// The keys never move; the offsets sit directly after the key capacity,
    /// so widening or narrowing the node moves them and nothing else.
    ///
    /// `self` must view whichever of the two node sizes is larger, so that
    /// both homes are in bounds: call it after widening, before narrowing.
    /// The capacity header is updated here, and both spare regions are zeroed
    /// so the buffer stays canonical.
    pub fn setCapacity(self: Index, to_cap: usize) void {
        const from_cap = self.maxKeys();
        if (to_cap == from_cap) return;
        const n = self.numKeys();
        assert(n <= to_cap);

        const from: [*]u32 = @ptrCast(self.n.ptr + index_node_start + from_cap);
        const to: [*]u32 = @ptrCast(self.n.ptr + index_node_start + to_cap);
        if (to_cap > from_cap) {
            std.mem.copyBackwards(u32, to[0..n], from[0..n]);
        } else {
            std.mem.copyForwards(u32, to[0..n], from[0..n]);
        }

        self.setMaxKeys(to_cap);
        @memset(self.n[index_node_start + n .. index_node_start + to_cap], 0);
        @memset(to[n..to_cap], 0);
    }
};

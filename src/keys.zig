//! The keys node: a `[]u64` view over the front of a bitmap's flat buffer,
//! mapping each 48-bit key to the offset of its container.
//!
//! Layout, in u64 units:
//!
//! | index    | meaning                                            |
//! |----------|----------------------------------------------------|
//! | 0        | node size in **u16** units (always a multiple of 4) |
//! | 1        | number of keys                                     |
//! | 2 + 2i   | key i (top 48 bits of a value)                     |
//! | 3 + 2i   | offset of container i, in u16 units                |
//!
//! Ported from sroar's keys.go.

const std = @import("std");
const assert = std.debug.assert;

/// The high 48 bits of a value select its container; the low 16 select the bit.
pub const key_mask: u64 = 0xFFFF_FFFF_FFFF_0000;

pub const index_node_size: usize = 0;
pub const index_num_keys: usize = 1;
pub const index_node_start: usize = 2;

fn keyOffset(i: usize) usize {
    return index_node_start + 2 * i;
}

fn valOffset(i: usize) usize {
    return index_node_start + 2 * i + 1;
}

/// A borrowed view of the keys node. Never store one across a call that can
/// grow the buffer: growth reallocates and the view dangles.
pub const Keys = struct {
    n: []u64,

    /// Node size in u16 units.
    pub fn size(self: Keys) usize {
        return @intCast(self.n[index_node_size]);
    }

    /// Number of keys currently stored.
    pub fn numKeys(self: Keys) usize {
        return @intCast(self.n[index_num_keys]);
    }

    /// Number of key/offset pairs the node has room for.
    pub fn maxKeys(self: Keys) usize {
        return (self.n.len - index_node_start) / 2;
    }

    /// True when no further key can be inserted without growing the node.
    pub fn isFull(self: Keys) bool {
        return self.numKeys() == self.maxKeys();
    }

    /// Key at index i (already masked to its top 48 bits).
    pub fn key(self: Keys, i: usize) u64 {
        assert(i < self.numKeys());
        return self.n[keyOffset(i)];
    }

    /// Container offset at index i, in u16 units.
    pub fn val(self: Keys, i: usize) usize {
        assert(i < self.numKeys());
        return @intCast(self.n[valOffset(i)]);
    }

    pub fn setNodeSize(self: Keys, sz: usize) void {
        self.n[index_node_size] = sz;
    }

    pub fn setNumKeys(self: Keys, num: usize) void {
        assert(num <= self.maxKeys());
        self.n[index_num_keys] = num;
    }

    pub fn setKeyAt(self: Keys, i: usize, k: u64) void {
        self.n[keyOffset(i)] = k;
    }

    pub fn setValAt(self: Keys, i: usize, v: usize) void {
        self.n[valOffset(i)] = v;
    }

    /// Returns the index of the smallest key >= k, or numKeys() if there is none.
    pub fn search(self: Keys, k: u64) usize {
        var lo: usize = 0;
        var hi: usize = self.numKeys();
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.n[keyOffset(mid)] < k) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    /// Returns the container offset registered for k, or null if k has no container.
    pub fn getValue(self: Keys, k: u64) ?usize {
        const masked = k & key_mask;
        const idx = self.search(masked);
        if (idx >= self.numKeys()) return null;
        if (self.key(idx) != masked) return null;
        return self.val(idx);
    }

    /// Inserts key k with offset v, or updates v if k is already present.
    /// Returns true when a new key was added. The caller guarantees room: the
    /// node is grown as soon as it becomes full, so it is never full on entry.
    pub fn set(self: Keys, k: u64, v: usize) bool {
        const n = self.numKeys();
        const idx = self.search(k);
        if (idx == n) {
            assert(!self.isFull());
            self.setNumKeys(n + 1);
            self.setKeyAt(idx, k);
            self.setValAt(idx, v);
            return true;
        }
        if (self.key(idx) == k) {
            self.setValAt(idx, v);
            return false;
        }
        assert(self.key(idx) > k);
        assert(!self.isFull());
        self.moveRight(idx);
        self.setNumKeys(n + 1);
        self.setKeyAt(idx, k);
        self.setValAt(idx, v);
        return true;
    }

    /// Opens a free pair at index lo by shifting [lo, numKeys) one pair right.
    fn moveRight(self: Keys, lo: usize) void {
        const hi = self.numKeys();
        assert(!self.isFull());
        std.mem.copyBackwards(
            u64,
            self.n[keyOffset(lo + 1)..keyOffset(hi + 1)],
            self.n[keyOffset(lo)..keyOffset(hi)],
        );
    }

    /// Shifts every offset strictly greater than `beyond` by `by`. The
    /// comparison is strict so that the container living at `beyond` itself,
    /// whose own start did not move, is left alone.
    pub fn updateOffsets(self: Keys, beyond: usize, by: usize, add: bool) void {
        var i: usize = 0;
        while (i < self.numKeys()) : (i += 1) {
            const off = self.val(i);
            if (off <= beyond) continue;
            if (add) {
                self.setValAt(i, off + by);
            } else {
                assert(off >= by);
                self.setValAt(i, off - by);
            }
        }
    }
};

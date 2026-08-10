//! Unit tests for `keys.zig`: search, ordered insertion and offset fixups over
//! a standalone keys node.

const std = @import("std");
const keys = @import("keys.zig");

const testing = std.testing;

const Keys = keys.Keys;
const index_node_start = keys.index_node_start;

/// Builds a standalone node with room for `pairs` keys, as init() would.
fn testNode(backing: []u64, pairs: usize) Keys {
    const n = index_node_start + 2 * pairs;
    @memset(backing[0..n], 0);
    const ks = Keys{ .n = backing[0..n] };
    ks.setNodeSize(n * 4);
    ks.setNumKeys(0);
    return ks;
}

test "search on an empty node" {
    var backing: [64]u64 = undefined;
    const ks = testNode(&backing, 4);
    try testing.expectEqual(@as(usize, 0), ks.search(0));
    try testing.expectEqual(@as(usize, 0), ks.search(1 << 32));
    try testing.expectEqual(@as(?usize, null), ks.getValue(0));
}

test "set keeps keys sorted and search finds the lower bound" {
    var backing: [64]u64 = undefined;
    const ks = testNode(&backing, 8);

    try testing.expect(ks.set(0, 24));
    try testing.expect(ks.set(3 << 16, 200));
    try testing.expect(ks.set(1 << 16, 100)); // inserted in the middle
    try testing.expect(ks.set(2 << 16, 150));

    try testing.expectEqual(@as(usize, 4), ks.numKeys());
    try testing.expectEqual(@as(u64, 0), ks.key(0));
    try testing.expectEqual(@as(u64, 1 << 16), ks.key(1));
    try testing.expectEqual(@as(u64, 2 << 16), ks.key(2));
    try testing.expectEqual(@as(u64, 3 << 16), ks.key(3));
    try testing.expectEqual(@as(usize, 24), ks.val(0));
    try testing.expectEqual(@as(usize, 100), ks.val(1));
    try testing.expectEqual(@as(usize, 150), ks.val(2));
    try testing.expectEqual(@as(usize, 200), ks.val(3));

    // Re-setting an existing key updates the offset and reports "not added".
    try testing.expect(!ks.set(1 << 16, 111));
    try testing.expectEqual(@as(usize, 111), ks.val(1));
    try testing.expectEqual(@as(usize, 4), ks.numKeys());

    try testing.expectEqual(@as(?usize, 24), ks.getValue(0x1234));
    try testing.expectEqual(@as(?usize, 111), ks.getValue((1 << 16) | 0xFFFF));
    try testing.expectEqual(@as(?usize, null), ks.getValue(4 << 16));
    try testing.expectEqual(@as(usize, 4), ks.search(4 << 16));
}

test "isFull and maxKeys" {
    var backing: [64]u64 = undefined;
    const ks = testNode(&backing, 2);
    try testing.expectEqual(@as(usize, 2), ks.maxKeys());
    try testing.expect(!ks.isFull());
    _ = ks.set(0, 8);
    try testing.expect(!ks.isFull());
    _ = ks.set(1 << 16, 16);
    try testing.expect(ks.isFull());
}

test "updateOffsets shifts only offsets beyond the boundary" {
    var backing: [64]u64 = undefined;
    const ks = testNode(&backing, 8);
    _ = ks.set(0, 100);
    _ = ks.set(1 << 16, 200);
    _ = ks.set(2 << 16, 300);

    ks.updateOffsets(200, 64, true);
    try testing.expectEqual(@as(usize, 100), ks.val(0));
    try testing.expectEqual(
        @as(usize, 200),
        ks.val(1),
    ); // at the boundary: unmoved
    try testing.expectEqual(@as(usize, 364), ks.val(2));

    ks.updateOffsets(200, 64, false);
    try testing.expectEqual(@as(usize, 300), ks.val(2));
}

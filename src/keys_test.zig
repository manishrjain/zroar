//! Unit tests for `keys.zig`: search, ordered insertion and offset fixups over
//! a standalone keys node.

const std = @import("std");
const keys = @import("keys.zig");

const testing = std.testing;

const Index = keys.Index;
const index_node_start = keys.index_node_start;

/// Builds a standalone node with room for `cap` keys, as init() would.
fn testNode(backing: []u64, cap: usize) Index {
    const size = keys.nodeSizeFor(cap);
    const n = size / 4;
    @memset(backing[0..n], 0);
    const ks = Index{ .n = backing[0..n] };
    ks.setNodeSize(size);
    ks.setCapacity(cap); // also declares 0 keys, over a zeroed node
    return ks;
}

test "search on an empty node" {
    var backing: [64]u64 = undefined;
    const ks = testNode(&backing, 4);
    try testing.expectEqual(@as(usize, 0), ks.search(0));
    try testing.expectEqual(@as(usize, 0), ks.search(1 << 32));
    try testing.expectEqual(@as(?usize, null), ks.getOffset(0));
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
    try testing.expectEqual(@as(usize, 24), ks.offset(0));
    try testing.expectEqual(@as(usize, 100), ks.offset(1));
    try testing.expectEqual(@as(usize, 150), ks.offset(2));
    try testing.expectEqual(@as(usize, 200), ks.offset(3));

    // Re-setting an existing key updates the offset and reports "not added".
    try testing.expect(!ks.set(1 << 16, 111));
    try testing.expectEqual(@as(usize, 111), ks.offset(1));
    try testing.expectEqual(@as(usize, 4), ks.numKeys());

    try testing.expectEqual(@as(?usize, 24), ks.getOffset(0x1234));
    try testing.expectEqual(@as(?usize, 111), ks.getOffset((1 << 16) | 0xFFFF));
    try testing.expectEqual(@as(?usize, null), ks.getOffset(4 << 16));
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

    ks.offsets().shiftPast(200, 64, true);
    try testing.expectEqual(@as(usize, 100), ks.offset(0));
    try testing.expectEqual(
        @as(usize, 200),
        ks.offset(1),
    ); // at the boundary: unmoved
    try testing.expectEqual(@as(usize, 364), ks.offset(2));

    ks.offsets().shiftPast(200, 64, false);
    try testing.expectEqual(@as(usize, 300), ks.offset(2));
}

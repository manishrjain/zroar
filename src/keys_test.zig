// Copyright 2026 Manish R Jain
// SPDX-License-Identifier: Apache-2.0

//! Unit tests for `keys.zig`: search, ordered insertion and offset fixups over
//! a standalone keys node.

const std = @import("std");
const keys = @import("keys.zig");
const stats_mod = @import("stats.zig");

/// These tests exercise the container and keys kernels directly rather than
/// through a Bitmap, so they have no counters of their own to feed. The
/// counting is covered by stats_test.zig; here it is deliberately discarded.
var sink: stats_mod.Sink = .{};

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

    try testing.expect(ks.set(0, 24, &sink));
    try testing.expect(ks.set(3 << 16, 200, &sink));
    try testing.expect(ks.set(1 << 16, 100, &sink)); // inserted in the middle
    try testing.expect(ks.set(2 << 16, 150, &sink));

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
    try testing.expect(!ks.set(1 << 16, 111, &sink));
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
    _ = ks.set(0, 8, &sink);
    try testing.expect(!ks.isFull());
    _ = ks.set(1 << 16, 16, &sink);
    try testing.expect(ks.isFull());
}

test "updateOffsets shifts only offsets beyond the boundary" {
    var backing: [64]u64 = undefined;
    const ks = testNode(&backing, 8);
    _ = ks.set(0, 100, &sink);
    _ = ks.set(1 << 16, 200, &sink);
    _ = ks.set(2 << 16, 300, &sink);

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

test "getValue's neighbourhood hint never changes an answer" {
    // Ascending hits and misses (the case the hint serves), a random stream
    // (the case it must stay out of the way of), and two nodes taken in
    // turns (the hint's node changes under it), all checked against a plain
    // search. The hint is thread-local state, so this also runs after every
    // other test has left it pointing wherever it pleased.
    const a_backing = try testing.allocator.alloc(u64, 2 + 2 * 3000);
    defer testing.allocator.free(a_backing);
    const b_backing = try testing.allocator.alloc(u64, 2 + 2 * 3000);
    defer testing.allocator.free(b_backing);
    const a = testNode(a_backing, 3000);
    const b = testNode(b_backing, 3000);
    var i: u64 = 0;
    while (i < 3000) : (i += 1) {
        _ = a.set(i << 16, i, &sink); // every key
        if (i % 3 == 0) _ = b.set(i << 16, i, &sink); // every third key
    }
    const nodes = [_]Keys{ a, b };

    const check = struct {
        fn run(ks: Keys, k: u64) !void {
            const want = ks.search(k);
            const got = ks.getValue(k);
            const hit = want < ks.numKeys() and ks.key(want) == k;
            try testing.expectEqual(hit, got != null);
            if (got) |v| try testing.expectEqual(ks.val(want), v);
        }
    }.run;

    // Ascending, running past the end of both nodes.
    var k: u64 = 0;
    while (k < 3200) : (k += 1) {
        for (nodes) |ks| try check(ks, k << 16);
    }
    // Random, alternating nodes.
    var prng = std.Random.DefaultPrng.init(11);
    const rnd = prng.random();
    var t: usize = 0;
    while (t < 20_000) : (t += 1) {
        try check(nodes[t & 1], rnd.uintLessThan(u64, 3200) << 16);
    }
}

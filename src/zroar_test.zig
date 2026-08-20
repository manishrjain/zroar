// Copyright 2026 Manish R Jain
// SPDX-License-Identifier: Apache-2.0

//! Unit tests for `zroar.zig`: point operations, container and keys-node
//! growth, serialization round trips, and the set operations checked against a
//! `std.AutoHashMapUnmanaged(u64, void)` reference set.

const std = @import("std");
const zroar = @import("zroar.zig");
const container = @import("container.zig");
const test_util = @import("test_util.zig");

const Bitmap = zroar.Bitmap;
const key_mask = zroar.key_mask;
const max_node_growth = zroar.max_node_growth;
const min_buffer_bytes = zroar.min_buffer_bytes;
const testing = std.testing;

/// Comfortably past the array-container ceiling, whatever `array_sizes`
/// currently ends at. Tests that want a bitmap container ask for this many
/// values rather than restating the ladder, which would otherwise have to be
/// re-derived by hand every time the ladder is tuned.
const past_array_ceiling: u64 = container.max_array_values + 200;

// Helpers `prop_test.zig` needs too, so they live in `test_util.zig`.
const RefSet = test_util.RefSet;
const checkInvariants = test_util.checkInvariants;
const testBitmap = test_util.testBitmap;
const testRefSet = test_util.testRefSet;
const refAnd = test_util.refAnd;
const refAndNot = test_util.refAndNot;
const refOr = test_util.refOr;
const expectFusedAgree = test_util.expectFusedCardinalities;

/// Type of the container holding `x`'s key. Test-only introspection.
fn containerTypeOf(bm: *const Bitmap, x: u64) container.Type {
    const offset = bm.keys().getValue(x & key_mask).?;
    return container.getType(bm.getContainer(offset));
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

    // Well past the array-container ceiling.
    const n = past_array_ceiling;
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

    // The top ladder step (max_array_size u16s) holds max_array_values
    // values, and the insert that fills it triggers the bitmap conversion.
    var i: u64 = 0;
    while (i < container.max_array_values - 1) : (i += 1) _ = try bm.set(i);
    try testing.expectEqual(container.Type.array, containerTypeOf(&bm, 0));

    _ = try bm.set(i);
    try testing.expectEqual(container.Type.bitmap, containerTypeOf(&bm, 0));
    try testing.expectEqual(
        @as(u64, container.max_array_values),
        bm.getCardinality(),
    );
    try checkInvariants(&bm);

    var j: u64 = 0;
    while (j < container.max_array_values) : (j += 1) {
        try testing.expect(bm.contains(j));
    }
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

    // Every offset must still point at the right container after all the
    // shifts.
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
        // the neighbour still resolves
        try testing.expect(bm.contains(1 << 32));

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

    // min_size - start_idx values fit, but the last of them leaves no free
    // slot, so `set` must expand before returning: a reader never sees a full
    // container.
    const capacity = container.min_size - container.start_idx;
    var i: u64 = 0;
    while (i + 1 < capacity) : (i += 1) {
        _ = try bm.set(i);
        const c = bm.getContainer(bm.keys().val(0));
        try testing.expectEqual(container.min_size, container.size(c));
        try checkInvariants(&bm);
    }
    _ = try bm.set(i);
    const grown = bm.getContainer(bm.keys().val(0));
    // The next size up the ladder, whatever the ladder says it is.
    try testing.expectEqual(
        container.nextArraySize(container.min_size),
        container.size(grown),
    );
    try testing.expectEqual(@as(u64, capacity), bm.getCardinality());
    try checkInvariants(&bm);
}

test "keys-node growth past the doubling cap stays 8-byte aligned" {
    var bm = try Bitmap.init(testing.allocator);
    defer bm.deinit();

    // The node doubles 24, 48, ... 98304 u16s; the step beyond that is capped
    // at max_node_growth. 98304 u16s is 12287 key/offset pairs, so one more
    // key than that exercises the capped path.
    const num_keys = 12_400;
    var k: u64 = 0;
    while (k < num_keys) : (k += 1) _ = try bm.set(k << 16);

    try testing.expectEqual(@as(usize, num_keys), bm.keys().numKeys());
    // Uncapped doubling would have produced 196608 u16s here.
    try testing.expectEqual(
        @as(usize, 98304 + max_node_growth),
        bm.keys().size(),
    );
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
        while (j < past_array_ceiling) : (j += 1) {
            _ = try bm.set((k << 16) | j);
        }
    }
    try testing.expectEqual(
        @as(u64, num_keys * past_array_ceiling),
        bm.getCardinality(),
    );
    try checkInvariants(&bm);

    k = 0;
    while (k < num_keys) : (k += 1) {
        try testing.expectEqual(
            container.Type.bitmap,
            containerTypeOf(&bm, k << 16),
        );
        var j: u64 = 0;
        while (j < past_array_ceiling) : (j += 1) {
            try testing.expect(bm.contains((k << 16) | j));
        }
        try testing.expect(!bm.contains((k << 16) | past_array_ceiling));
    }
}

test "growing a mid-buffer container relocates it to the end" {
    var bm = try Bitmap.init(testing.allocator);
    defer bm.deinit();

    // A second key puts its container behind key 0's, so growing key 0's
    // container can no longer be an append.
    _ = try bm.set(1 << 16);
    const behind = bm.keys().getValue(1 << 16).?;
    try testing.expect(bm.keys().getValue(0).? < behind);

    // Fill key 0's container to capacity; the expansion must move it past
    // the other container rather than shift that container right.
    const capacity = container.min_size - container.start_idx;
    var i: u64 = 0;
    while (i < capacity) : (i += 1) _ = try bm.set(i);

    try testing.expect(
        bm.keys().getValue(0).? > bm.keys().getValue(1 << 16).?,
    );
    try testing.expect(bm.dead > 0);
    try checkInvariants(&bm);

    try testing.expectEqual(@as(u64, capacity + 1), bm.getCardinality());
    i = 0;
    while (i < capacity) : (i += 1) try testing.expect(bm.contains(i));
    try testing.expect(bm.contains(1 << 16));
}

test "a mid-buffer array converts to bitmap by relocating" {
    var bm = try Bitmap.init(testing.allocator);
    defer bm.deinit();

    // Stop one value short of the array ceiling, then pin a second container
    // behind key 0's, so the conversion cannot happen in place.
    var i: u64 = 0;
    while (i + 1 < container.max_array_values) : (i += 1) _ = try bm.set(i);
    try testing.expectEqual(container.Type.array, containerTypeOf(&bm, 0));
    _ = try bm.set(1 << 16);

    _ = try bm.set(container.max_array_values - 1); // full -> convert

    try testing.expectEqual(container.Type.bitmap, containerTypeOf(&bm, 0));
    try testing.expect(
        bm.keys().getValue(0).? > bm.keys().getValue(1 << 16).?,
    );
    try checkInvariants(&bm);

    try testing.expectEqual(
        @as(u64, container.max_array_values + 1),
        bm.getCardinality(),
    );
    i = 0;
    while (i < container.max_array_values) : (i += 1) {
        try testing.expect(bm.contains(i));
    }
    try testing.expect(bm.contains(1 << 16));
}

test "relocation keeps dead space under the cleanup bound" {
    var bm = try Bitmap.init(testing.allocator);
    defer bm.deinit();

    // Alternate between two keys so each container repeatedly finds itself
    // mid-buffer when it must grow.
    var i: u64 = 0;
    while (i < 3000) : (i += 1) {
        _ = try bm.set(i);
        _ = try bm.set((1 << 16) | i);
        try testing.expect(bm.dead * zroar.max_dead_divisor <= bm.data.len);
    }
    try checkInvariants(&bm);
    try testing.expectEqual(@as(u64, 6000), bm.getCardinality());

    // A buffer serialized with dead slots still in it reopens correctly.
    const buf = try bm.toBufferCopy(testing.allocator);
    defer testing.allocator.free(buf);
    var re = try Bitmap.fromBuffer(testing.allocator, buf, .borrow);
    defer re.deinit();
    try testing.expectEqual(@as(u64, 6000), re.getCardinality());
    try checkInvariants(&re);

    // cleanup reclaims every dead slot and resets the debt.
    const before = bm.data.len;
    bm.cleanup();
    try testing.expectEqual(@as(usize, 0), bm.dead);
    try testing.expect(bm.data.len <= before);
    try testing.expectEqual(@as(u64, 6000), bm.getCardinality());
    try checkInvariants(&bm);
    i = 0;
    while (i < 3000) : (i += 1) {
        try testing.expect(bm.contains(i));
        try testing.expect(bm.contains((1 << 16) | i));
    }
}

test "container relocation on a borrowed bitmap copies out" {
    var src = try Bitmap.init(testing.allocator);
    defer src.deinit();
    // Key 0's container one value short of full, with a second container
    // behind it, so the next set under key 0 must relocate.
    const capacity = container.min_size - container.start_idx;
    var i: u64 = 0;
    while (i + 1 < capacity) : (i += 1) _ = try src.set(i);
    _ = try src.set(1 << 16);

    const buf = try src.toBufferCopy(testing.allocator);
    defer testing.allocator.free(buf);

    var view = try Bitmap.fromBuffer(testing.allocator, buf, .borrow);
    defer view.deinit();
    try testing.expect(!view.owned);

    _ = try view.set(capacity - 1); // fills key 0's container: relocation
    try testing.expect(view.owned);
    try checkInvariants(&view);

    // The copied-out bitmap keeps working after further growth.
    _ = try view.set(0xFFFF);
    try testing.expectEqual(@as(u64, capacity + 2), view.getCardinality());
    i = 0;
    while (i < capacity) : (i += 1) try testing.expect(view.contains(i));
    try testing.expect(view.contains(1 << 16));
    try testing.expect(view.contains(0xFFFF));
}

test "remove from both container types" {
    var bm = try Bitmap.init(testing.allocator);
    defer bm.deinit();

    // Key 0 stays an array container, key 1 is promoted to a bitmap.
    var i: u64 = 0;
    while (i < 100) : (i += 1) _ = try bm.set(i);
    while (i < 100 + past_array_ceiling) : (i += 1) {
        _ = try bm.set((1 << 16) | (i - 100));
    }
    try testing.expectEqual(container.Type.array, containerTypeOf(&bm, 0));
    try testing.expectEqual(
        container.Type.bitmap,
        containerTypeOf(&bm, 1 << 16),
    );

    try testing.expect(bm.remove(50));
    try testing.expect(!bm.remove(50));
    try testing.expect(!bm.contains(50));
    try testing.expect(bm.contains(49) and bm.contains(51));

    try testing.expect(bm.remove((1 << 16) | 2000));
    try testing.expect(!bm.remove((1 << 16) | 2000));
    try testing.expect(!bm.contains((1 << 16) | 2000));

    try testing.expect(!bm.remove(1 << 32)); // key not present at all
    try testing.expectEqual(
        @as(u64, 100 + past_array_ceiling - 2),
        bm.getCardinality(),
    );
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
    while (i < past_array_ceiling) : (i += 1) _ = try bm.set(i);
    try testing.expectEqual(container.Type.bitmap, containerTypeOf(&bm, 0));

    var it = bm.iterator();
    try testing.expectEqual(@as(?u64, 0), it.next()); // not an end sentinel
    var expected: u64 = 1;
    while (expected < past_array_ceiling) : (expected += 1) {
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
    try testing.expectEqual(
        @as(?u64, ref.items[ref.items.len - 1]),
        bm.maximum(),
    );
    try checkInvariants(&bm);
}

test "toArrayInto agrees with the iterator, container type by container type" {
    var bm = try Bitmap.init(testing.allocator);
    defer bm.deinit();

    // Enough values in the low key to force a bitmap container, a handful in
    // the next to leave an array container, and a gap so an empty container
    // is walked too.
    var i: u64 = 0;
    while (i < 5000) : (i += 1) _ = try bm.set(i);
    for ([_]u64{ 3, 17, 0xFFFF }) |v| _ = try bm.set((1 << 16) | v);
    _ = try bm.set((7 << 48) | 42);

    const card: usize = @intCast(bm.getCardinality());
    const out = try testing.allocator.alloc(u64, card);
    defer testing.allocator.free(out);
    bm.toArrayInto(out);

    // The iterator is the reference: the bulk path exists only to be a faster
    // way of producing exactly what it produces.
    var it = bm.iterator();
    var n: usize = 0;
    while (it.next()) |v| : (n += 1) {
        try testing.expectEqual(v, out[n]);
    }
    try testing.expectEqual(card, n);

    // Writing into a slice of a larger reusable buffer is the intended use.
    const big = try testing.allocator.alloc(u64, card + 64);
    defer testing.allocator.free(big);
    @memset(big, 0xAA);
    bm.toArrayInto(big[0..card]);
    try testing.expectEqualSlices(u64, out, big[0..card]);
    for (big[card..]) |v| try testing.expectEqual(@as(u64, 0xAA), v);
}

test "compact shrinks the buffer, preserves content, and stays mutable" {
    var bm = try Bitmap.init(testing.allocator);
    defer bm.deinit();

    var ref = std.ArrayListUnmanaged(u64).empty;
    defer ref.deinit(testing.allocator);

    var prng = std.Random.DefaultPrng.init(0x5A1AD);
    const rnd = prng.random();
    var i: usize = 0;
    while (i < 20_000) : (i += 1) {
        // A dense low key (bitmap container), a mid key that lands just under
        // a ladder step, and scattered high keys with a value or two each.
        const x = switch (i % 3) {
            0 => rnd.uintLessThan(u64, 20_000),
            1 => (1 << 16) | rnd.uintLessThan(u64, 1200),
            else => (rnd.uintLessThan(u64, 500) << 32) |
                rnd.uintLessThan(u64, 4),
        };
        if (try bm.set(x)) try ref.append(testing.allocator, x);
    }
    std.mem.sort(u64, ref.items, {}, std.sort.asc(u64));

    const before = bm.toBuffer().len;
    try bm.compact();
    const after = bm.toBuffer().len;
    try testing.expect(after < before);
    try checkInvariants(&bm);

    // Content is untouched.
    const got = try bm.toArray(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u64, ref.items, got);

    // Compacting again is a no-op: it is already as small as it goes.
    try bm.compact();
    try testing.expectEqual(after, bm.toBuffer().len);

    // And it is still an ordinary bitmap: writing into it works, including
    // into containers that compaction sized down to their last free slot.
    for (ref.items[0..64]) |v| try testing.expect(!try bm.set(v));
    var added: usize = 0;
    var v: u64 = 1;
    while (added < 2000) : (v += 7) {
        if (try bm.set((7 << 48) | (v % 60_000))) added += 1;
    }
    try checkInvariants(&bm);
    for (ref.items) |x| try testing.expect(bm.contains(x));
}

test "compact round trips through a buffer" {
    var bm = try Bitmap.init(testing.allocator);
    defer bm.deinit();
    var i: u64 = 0;
    // Enough in one key to be a bitmap container, but sparse enough that an
    // array container is smaller — so compact must convert it back.
    while (i < 1500) : (i += 1) _ = try bm.set(i * 40);
    while (i < 3000) : (i += 1) _ = try bm.set((9 << 32) | i);

    const card = bm.getCardinality();
    try bm.compact();
    try testing.expectEqual(card, bm.getCardinality());

    const buf = try bm.toBufferCopy(testing.allocator);
    defer testing.allocator.free(buf);
    var reopened = try Bitmap.fromBuffer(testing.allocator, buf, .borrow);
    defer reopened.deinit();
    try testing.expectEqual(card, reopened.getCardinality());

    const a = try bm.toArray(testing.allocator);
    defer testing.allocator.free(a);
    const b = try reopened.toArray(testing.allocator);
    defer testing.allocator.free(b);
    try testing.expectEqualSlices(u64, a, b);
    try checkInvariants(&reopened);
}

test "compact on an empty bitmap keeps key 0 and stays usable" {
    var bm = try Bitmap.init(testing.allocator);
    defer bm.deinit();
    try bm.compact();
    try checkInvariants(&bm);
    try testing.expectEqual(@as(u64, 0), bm.getCardinality());
    try testing.expect(try bm.set(1 << 40));
    try testing.expect(bm.contains(1 << 40));
    try checkInvariants(&bm);
}

test "toArrayInto on an empty bitmap writes nothing" {
    var bm = try Bitmap.init(testing.allocator);
    defer bm.deinit();
    var out: [0]u64 = undefined;
    bm.toArrayInto(&out);
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

    var reopened = try Bitmap.fromBuffer(testing.allocator, buf, .borrow);
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

    var reopened = try Bitmap.fromBuffer(testing.allocator, buf, .borrow);
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
    var short: [min_buffer_bytes - 2]u8 align(8) =
        .{0} ** (min_buffer_bytes - 2);

    var a = try Bitmap.fromBuffer(testing.allocator, &odd, .borrow);
    defer a.deinit();
    try testing.expect(a.owned and a.isEmpty());

    var b = try Bitmap.fromBuffer(testing.allocator, &short, .borrow);
    defer b.deinit();
    try testing.expect(b.owned and b.isEmpty());

    var c = try Bitmap.fromBufferCopy(testing.allocator, &.{});
    defer c.deinit();
    try testing.expect(c.owned and c.isEmpty());
}

test "mutating a borrowed bitmap copies out, even without growth" {
    var src = try Bitmap.init(testing.allocator);
    defer src.deinit();
    _ = try src.set(1);
    _ = try src.set(2);

    const buf = try src.toBufferCopy(testing.allocator);
    defer testing.allocator.free(buf);
    const pristine = try testing.allocator.dupe(u8, buf);
    defer testing.allocator.free(pristine);

    {
        // Key 0's array container has a free slot, so this set would fit in
        // place — the copy must happen anyway, because a mutation may never
        // write to the caller's buffer.
        var view = try Bitmap.fromBuffer(testing.allocator, buf, .borrow);
        defer view.deinit();
        try testing.expect(try view.set(3));
        try testing.expect(view.owned);
        try testing.expect(view.contains(3));
        try testing.expectEqual(@as(u64, 3), view.getCardinality());
    }

    // The caller's buffer still reads back as the original two values.
    try testing.expectEqualSlices(u8, pristine, buf);
    var again = try Bitmap.fromBuffer(testing.allocator, buf, .borrow);
    defer again.deinit();
    try testing.expect(!again.contains(3));
    try testing.expectEqual(@as(u64, 2), again.getCardinality());
}

test "reads on a borrowed bitmap never copy" {
    var src = try Bitmap.init(testing.allocator);
    defer src.deinit();
    for (0..100) |i| _ = try src.set(i * 7);

    const buf = try src.toBufferCopy(testing.allocator);
    defer testing.allocator.free(buf);

    var view = try Bitmap.fromBuffer(testing.allocator, buf, .borrow);
    defer view.deinit();
    for (0..100) |i| try testing.expect(view.contains(i * 7));
    try testing.expectEqual(@as(u64, 100), view.getCardinality());
    try testing.expect(!view.owned);
}

test "ensureOwned unlocks the infallible mutators on a borrowed bitmap" {
    var src = try Bitmap.init(testing.allocator);
    defer src.deinit();
    for (0..10) |i| _ = try src.set(i);

    const buf = try src.toBufferCopy(testing.allocator);
    defer testing.allocator.free(buf);
    const pristine = try testing.allocator.dupe(u8, buf);
    defer testing.allocator.free(pristine);

    var view = try Bitmap.fromBuffer(testing.allocator, buf, .borrow);
    defer view.deinit();
    try view.ensureOwned();
    try testing.expect(view.remove(3));
    try testing.expect(!view.contains(3));
    try testing.expectEqual(@as(u64, 9), view.getCardinality());
    try testing.expectEqualSlices(u8, pristine, buf);
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

    var view = try Bitmap.fromBuffer(testing.allocator, buf, .borrow);
    defer view.deinit();
    try testing.expect(!view.owned);

    // A brand new key allocates a container, so this mutation also grows;
    // the copy-out happens up front either way.
    try testing.expect(try view.set(1 << 48));
    try testing.expect(view.owned);

    try testing.expectEqualSlices(u8, pristine, buf);
    try testing.expect(view.contains(1));
    try testing.expect(view.contains(2));
    try testing.expect(view.contains(1 << 48));
    try testing.expectEqual(@as(u64, 3), view.getCardinality());
    try checkInvariants(&view);

    // The untouched buffer still reads back as the original bitmap.
    var reread = try Bitmap.fromBuffer(testing.allocator, buf, .borrow);
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

    var view = try Bitmap.fromBuffer(testing.allocator, buf, .borrow);
    defer view.deinit();

    // Enough work to force many reallocations and a container conversion.
    var i: u64 = 0;
    while (i < 5000) : (i += 1) _ = try view.set((i % 50 << 32) | i);
    try testing.expect(view.owned);
    try testing.expect(view.contains(9));
    try checkInvariants(&view);

    i = 0;
    while (i < 5000) : (i += 1) {
        try testing.expect(view.contains((i % 50 << 32) | i));
    }
}

test "fromBufferCopy owns its data and tolerates unaligned input" {
    var src = try Bitmap.init(testing.allocator);
    defer src.deinit();
    var i: u64 = 0;
    while (i < 500) : (i += 1) _ = try src.set(i * 3);

    const buf = try src.toBufferCopy(testing.allocator);
    defer testing.allocator.free(buf);

    // Copy into a deliberately misaligned window to prove no alignment is
    // assumed.
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

/// The bitmap holds exactly the reference set's values, and its layout is
/// sound.
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
    // runs is bitmap ∩ bitmap and only the overlap decides the result's
    // shape.
    var a = try Bitmap.init(testing.allocator);
    defer a.deinit();
    var i: u64 = 0;
    while (i < 5000) : (i += 1) _ = try a.set(i);
    try testing.expectEqual(container.Type.bitmap, containerTypeOf(&a, 0));

    // The two overlap in exactly as many values as an array container can
    // hold, so the result must be an array at the ladder's last step: one
    // value more and it would have had to stay a bitmap.
    const overlap = container.max_array_values - 1;
    var small = try Bitmap.init(testing.allocator);
    defer small.deinit();
    i = 5000 - overlap;
    while (i < 5000 - overlap + 5000) : (i += 1) _ = try small.set(i);
    try testing.expectEqual(container.Type.bitmap, containerTypeOf(&small, 0));

    var got = try Bitmap.And(testing.allocator, &a, &small);
    defer got.deinit();
    try testing.expectEqual(@as(u64, overlap), got.getCardinality());
    try testing.expectEqual(container.Type.array, containerTypeOf(&got, 0));
    const got_c = got.getContainer(got.keys().val(0));
    try testing.expectEqual(container.max_array_size, container.size(got_c));
    try testing.expectEqual(@as(?u64, 5000 - overlap), got.minimum());
    try testing.expectEqual(@as(?u64, 4999), got.maximum());
    try checkInvariants(&got);
    try expectAndIsCompact(&got);

    // One value more and no array container fits, so the result stays a bitmap.
    var big = try Bitmap.init(testing.allocator);
    defer big.deinit();
    i = 5000 - overlap - 1;
    while (i < 5000 - overlap - 1 + 5000) : (i += 1) _ = try big.set(i);

    var got2 = try Bitmap.And(testing.allocator, &a, &big);
    defer got2.deinit();
    try testing.expectEqual(@as(u64, overlap + 1), got2.getCardinality());
    try testing.expectEqual(container.Type.bitmap, containerTypeOf(&got2, 0));
    try checkInvariants(&got2);
    try expectAndIsCompact(&got2);

    // A small array result is sized for itself, not for either operand.
    var sparse = try testBitmap(&.{ 3, 4998, 4999, 1 << 40 });
    defer sparse.deinit();
    var got3 = try Bitmap.And(testing.allocator, &a, &sparse);
    defer got3.deinit();
    try testing.expectEqual(@as(u64, 3), got3.getCardinality());
    const got3_c = got3.getContainer(got3.keys().val(0));
    try testing.expectEqual(container.min_size, container.size(got3_c));
    // key 1<<40 dropped
    try testing.expectEqual(@as(usize, 1), got3.keys().numKeys());
    try checkInvariants(&got3);
    try expectAndIsCompact(&got3);
}

test "And of disjoint bitmaps leaves only key 0" {
    // Shared keys whose values miss each other, plus keys held by one side
    // only.
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
    try testing.expectEqual(
        got.keys().size() + container.min_size,
        got.data.len,
    );
    try checkInvariants(&got);
    try expectAndIsCompact(&got);
}

test "Or sizes each result container to the result" {
    // Two arrays whose counts together pass the array ceiling but which mostly
    // overlap: the union is built bitmap-shaped and must still land as an
    // array, sized for itself.
    const n = 2000; // 2n past the ceiling, the 2500-value union under it
    comptime std.debug.assert(2 * n > container.max_array_values);
    comptime std.debug.assert(container.arraySizeFor(n + n / 4) != null);
    var a = try Bitmap.init(testing.allocator);
    defer a.deinit();
    var i: u64 = 0;
    while (i < n) : (i += 1) _ = try a.set(i);
    var b = try Bitmap.init(testing.allocator);
    defer b.deinit();
    i = n / 4;
    while (i < n / 4 + n) : (i += 1) _ = try b.set(i);
    try testing.expectEqual(container.Type.array, containerTypeOf(&a, 0));
    try testing.expectEqual(container.Type.array, containerTypeOf(&b, 0));

    var got = try Bitmap.Or(testing.allocator, &a, &b);
    defer got.deinit();
    try testing.expectEqual(@as(u64, n + n / 4), got.getCardinality());
    try testing.expectEqual(container.Type.array, containerTypeOf(&got, 0));
    try testing.expectEqual(
        container.arraySizeFor(n + n / 4).?,
        container.size(got.getContainer(got.keys().val(0))),
    );
    try checkInvariants(&got);
    try expectAndIsCompact(&got);

    // Disjoint arrays past the ceiling: the union really is a bitmap.
    var c = try Bitmap.init(testing.allocator);
    defer c.deinit();
    i = 10000;
    while (i < 10000 + n) : (i += 1) _ = try c.set(i);
    var got2 = try Bitmap.Or(testing.allocator, &a, &c);
    defer got2.deinit();
    try testing.expectEqual(@as(u64, 2 * n), got2.getCardinality());
    try testing.expectEqual(container.Type.bitmap, containerTypeOf(&got2, 0));
    try checkInvariants(&got2);
    try expectAndIsCompact(&got2);

    // Keys held by one side only are copied in at their own size, in key
    // order, and a container that andInPlace emptied contributes neither a
    // key nor a container. Both mixed-type kernels run under key 0.
    var dense = try Bitmap.init(testing.allocator);
    defer dense.deinit();
    i = 0;
    while (i < 5000) : (i += 1) _ = try dense.set(i);
    _ = try dense.set(1 << 32);
    _ = try dense.set(3 << 32);
    var sparse = try testBitmap(&.{ 5, 4999, 5000, 1 << 16, 1 << 32, 2 << 32 });
    defer sparse.deinit();
    sparse.andInPlace(&dense); // empties keys 1<<16 and 2<<32
    try testing.expectEqual(@as(usize, 4), sparse.keys().numKeys());

    var ra = try testRefSet(&.{ 5, 4999, 1 << 32, 3 << 32 });
    defer ra.deinit(testing.allocator);
    i = 0;
    while (i < 5000) : (i += 1) try ra.put(testing.allocator, i, {});

    for ([_][2]*const Bitmap{ .{ &dense, &sparse }, .{ &sparse, &dense } }) |pair| {
        var u = try Bitmap.Or(testing.allocator, pair[0], pair[1]);
        defer u.deinit();
        try expectSameAs(&ra, &u);
        try testing.expectEqual(container.Type.bitmap, containerTypeOf(&u, 0));
        try testing.expectEqual(container.Type.array, containerTypeOf(&u, 1 << 32));
        try testing.expectEqual(container.Type.array, containerTypeOf(&u, 3 << 32));
        // Only keys 0, 1<<32 and 3<<32 survive; the emptied ones are gone.
        try testing.expectEqual(@as(usize, 3), u.keys().numKeys());
        try checkInvariants(&u);
        try expectAndIsCompact(&u);
    }
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
    try testing.expectEqual(
        container.Type.array,
        containerTypeOf(&got, 1 << 32),
    );

    const buf = try got.toBufferCopy(testing.allocator);
    defer testing.allocator.free(buf);
    var reopened = try Bitmap.fromBuffer(testing.allocator, buf, .borrow);
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
    // The u7-popcount shape: overlapping runs long enough that a
    // bitmap∩bitmap chunk is fully set, which an unwidened @reduce would
    // wrap at 128.
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
    // never demoted
    try testing.expectEqual(container.Type.bitmap, containerTypeOf(&a, 0));
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
    // Key 0 starts as a min_size array and has to walk every ladder step up
    // to max_array_size and then convert to a bitmap as the unions get bigger.
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
    try testing.expectEqual(
        container.Type.bitmap,
        containerTypeOf(&s, 1 << 48),
    );
}

test "fromSortedList matches a set loop and round trips" {
    var prng = std.Random.DefaultPrng.init(0x5027);
    const rnd = prng.random();

    var vals: [6000]u64 = undefined;
    randomValues(rnd, &vals);
    // A dense run so at least one key needs a bitmap container, and duplicates
    // so the builder has to skip them.
    for (vals[0..5000], 0..) |*v, i| {
        v.* = (1 << 32) | (i % past_array_ceiling);
    }
    std.mem.sort(u64, &vals, {}, std.sort.asc(u64));

    var built = try Bitmap.fromSortedList(testing.allocator, &vals);
    defer built.deinit();

    var ref = try testRefSet(&vals);
    defer ref.deinit(testing.allocator);
    try expectSameAs(&ref, &built);
    try testing.expectEqual(
        container.Type.bitmap,
        containerTypeOf(&built, 1 << 32),
    );

    var looped = try testBitmap(&vals);
    defer looped.deinit();
    const a = try built.toArray(testing.allocator);
    defer testing.allocator.free(a);
    const b = try looped.toArray(testing.allocator);
    defer testing.allocator.free(b);
    try testing.expectEqualSlices(u64, b, a);

    const buf = try built.toBufferCopy(testing.allocator);
    defer testing.allocator.free(buf);
    var reopened = try Bitmap.fromBuffer(testing.allocator, buf, .borrow);
    defer reopened.deinit();
    try testing.expectEqualSlices(u16, built.data, reopened.data);
    try expectSameAs(&ref, &reopened);

    // Degenerate inputs.
    var none = try Bitmap.fromSortedList(testing.allocator, &.{});
    defer none.deinit();
    try testing.expect(none.isEmpty());
    try checkInvariants(&none);

    var one = try Bitmap.fromSortedList(
        testing.allocator,
        &.{std.math.maxInt(u64)},
    );
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
    // nothing removed yet
    try testing.expectEqual(keys_before, bm.keys().numKeys());
    try testing.expectEqual(len_before, bm.data.len);

    bm.cleanup();
    try testing.expect(bm.data.len < len_before);
    // key 0 and key 7
    try testing.expectEqual(@as(usize, 2), bm.keys().numKeys());
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
    var reopened = try Bitmap.fromBuffer(testing.allocator, buf, .borrow);
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
                const reopened = try Bitmap.fromBufferCopy(
                    testing.allocator,
                    buf,
                );
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

test "compact canonicalizes: equal sets give byte-identical buffers" {
    // The working buffer is allowed to carry dead bytes — array slack, dead
    // slots, the payloads of removed values — so two equal bitmaps need not
    // match byte for byte. compact() rebuilds into a zeroed buffer, so after
    // it they must. One bitmap takes the scenic route: extra values inserted
    // and removed again (stale payload past the cardinality), enough churn to
    // grow and relocate containers, and a spare key emptied by the removes.
    var scenic = try Bitmap.init(testing.allocator);
    defer scenic.deinit();
    var i: u64 = 0;
    while (i < 4000) : (i += 1) _ = try scenic.set(i * 3);
    _ = try scenic.set(1 << 40);
    i = 0;
    while (i < 4000) : (i += 1) {
        if (i % 3 != 0) _ = scenic.remove(i * 3);
    }
    _ = scenic.remove(1 << 40);

    var vals: std.ArrayListUnmanaged(u64) = .empty;
    defer vals.deinit(testing.allocator);
    i = 0;
    while (i < 4000) : (i += 3) try vals.append(testing.allocator, i * 3);
    var direct = try Bitmap.fromSortedList(testing.allocator, vals.items);
    defer direct.deinit();

    try scenic.compact();
    try direct.compact();
    try testing.expectEqualSlices(u16, direct.data, scenic.data);
    try checkInvariants(&scenic);
}

test "the format version is the buffer's first two bytes and is enforced" {
    var bm = try testBitmap(&.{ 1, 99, 1 << 40 });
    defer bm.deinit();
    const buf = try bm.toBufferCopy(testing.allocator);
    defer testing.allocator.free(buf);

    // Little-endian low 16 bits of the first u64: bytes 0 and 1 of the file.
    try testing.expectEqual(@as(u8, zroar.format_version), buf[0]);
    try testing.expectEqual(@as(u8, 0), buf[1]);

    var reopened = try Bitmap.fromBuffer(testing.allocator, buf, .borrow);
    defer reopened.deinit();
    try testing.expect(reopened.contains(1 << 40));

    // A version from the future (or a pre-versioning buffer, whose bytes
    // here are 0) must be refused, not misread.
    buf[0] = zroar.format_version + 1;
    try testing.expectError(
        error.UnsupportedFormatVersion,
        Bitmap.fromBuffer(testing.allocator, buf, .borrow),
    );
    try testing.expectError(
        error.UnsupportedFormatVersion,
        Bitmap.fromBufferCopy(testing.allocator, buf),
    );
    buf[0] = 0;
    try testing.expectError(
        error.UnsupportedFormatVersion,
        Bitmap.fromBuffer(testing.allocator, buf, .borrow),
    );

    // Restored, it opens again.
    buf[0] = zroar.format_version;
    var again = try Bitmap.fromBuffer(testing.allocator, buf, .borrow);
    defer again.deinit();
    try testing.expectEqual(@as(u64, 3), again.getCardinality());
}

test "fromBuffer with .own transfers the buffer, even on failure" {
    // Success: the bitmap frees the buffer in deinit, and a mutation works
    // on it directly instead of copying out. testing.allocator's leak check
    // is what verifies every free in this test.
    var bm = try testBitmap(&.{ 1, 99, 1 << 40 });
    defer bm.deinit();
    var owned = try Bitmap.fromBuffer(
        testing.allocator,
        try bm.toBufferCopy(testing.allocator),
        .own,
    );
    defer owned.deinit();
    try testing.expect(owned.contains(1 << 40));
    try testing.expect(try owned.set(7));
    try testing.expectEqual(@as(u64, 4), owned.getCardinality());

    // Version mismatch: the error path must free an owned buffer too.
    const bad = try bm.toBufferCopy(testing.allocator);
    bad[0] = zroar.format_version + 1;
    try testing.expectError(
        error.UnsupportedFormatVersion,
        Bitmap.fromBuffer(testing.allocator, bad, .own),
    );

    // Not-a-bitmap sizes: the empty-bitmap path frees an owned buffer too.
    const tiny = try testing.allocator.alignedAlloc(u8, .@"8", 8);
    var empty = try Bitmap.fromBuffer(testing.allocator, tiny, .own);
    defer empty.deinit();
    try testing.expect(empty.isEmpty());
}

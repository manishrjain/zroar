//! Tests for the optional counters in `stats.zig`.
//!
//! These run with the counters live: `stats.enabled` is true in test builds so
//! the accounting can be checked at all. What is asserted is the shape of each
//! count: which counter moves, and roughly in proportion to what. Never an
//! exact figure, since the ladder and the growth policy are both tuned, and
//! every exact number here would be a second place to update.

const std = @import("std");
const zroar = @import("zroar.zig");
const container = @import("container.zig");
const stats = @import("stats.zig");

const Bitmap = zroar.Bitmap;
const testing = std.testing;

test "counters are live in a test build" {
    try testing.expect(stats.enabled);
}

test "counters start at zero and belong to one bitmap" {
    var a = try Bitmap.init(testing.allocator);
    defer a.deinit();
    var b = try Bitmap.init(testing.allocator);
    defer b.deinit();
    try testing.expectEqual(@as(u64, 0), a.counters.sets);

    for (0..100) |i| _ = try a.set(i);
    // Every set is counted, including the ones that changed nothing.
    for (0..100) |i| _ = try a.set(i);
    try testing.expectEqual(@as(u64, 200), a.counters.sets);

    // b did none of that work and must not have been charged for it.
    try testing.expectEqual(@as(u64, 0), b.counters.sets);
}

test "growing a container past the ladder is counted as a grow" {
    var bm = try Bitmap.init(testing.allocator);
    defer bm.deinit();

    // Key 0's container starts at min_size and steps up the ladder. Filling
    // it past several steps must register that many grows and no relocations,
    // since it is the only container and so always last in the buffer.
    for (0..container.min_size * 8) |i| _ = try bm.set(i);
    try testing.expect(bm.counters.container_grows >= 3);
    try testing.expectEqual(@as(u64, 0), bm.counters.container_relocs);
    try testing.expectEqual(@as(u64, 0), bm.counters.abandoned_u16);
}

test "growing a container that is not last relocates and abandons its slot" {
    var bm = try Bitmap.init(testing.allocator);
    defer bm.deinit();

    // A second key puts a container after key 0's, so key 0's next growth has
    // to move to the end and leave its old slot behind.
    _ = try bm.set(1 << 20);
    for (0..container.min_size * 8) |i| _ = try bm.set(i);

    try testing.expect(bm.counters.container_relocs > 0);
    try testing.expect(bm.counters.container_grows >=
        bm.counters.container_relocs);
    try testing.expect(bm.counters.abandoned_u16 > 0);
}

test "out-of-order keys shift the node, in-order keys do not" {
    var ascending = try Bitmap.init(testing.allocator);
    defer ascending.deinit();
    for (1..200) |i| _ = try ascending.set(@as(u64, i) << 16);

    var descending = try Bitmap.init(testing.allocator);
    defer descending.deinit();
    var i: u64 = 199;
    while (i > 0) : (i -= 1) _ = try descending.set(i << 16);

    // Ascending keys always append, so nothing above them ever moves.
    try testing.expectEqual(@as(u64, 0), ascending.counters.node_shifted_u64);
    // Descending keys insert at the front every time, which is the quadratic
    // case: each of n insertions shifts everything already there.
    try testing.expect(descending.counters.node_shifted_u64 > 200);
    try testing.expectEqual(
        ascending.getCardinality(),
        descending.getCardinality(),
    );
}

test "array.add shifting is counted, and appending in order avoids it" {
    var appended = try Bitmap.init(testing.allocator);
    defer appended.deinit();
    for (0..500) |i| _ = try appended.set(i);
    try testing.expectEqual(@as(u64, 0), appended.counters.array_shifted_u16);

    // The same 500 values, inserted in the opposite order.
    var prepended = try Bitmap.init(testing.allocator);
    defer prepended.deinit();
    var i: u64 = 500;
    while (i > 0) : (i -= 1) _ = try prepended.set(i - 1);
    // Inserting below everything present shifts the whole tail each time.
    try testing.expect(prepended.counters.array_shifted_u16 > 500);

    // Identical results, so the counters are comparing two ways of doing the
    // very same work rather than two different amounts of it.
    const a = try appended.toArray(testing.allocator);
    defer testing.allocator.free(a);
    const b = try prepended.toArray(testing.allocator);
    defer testing.allocator.free(b);
    try testing.expectEqualSlices(u64, a, b);
}

test "counting never changes what is built" {
    // The derived counts in `set` and `setKey` re-run a search when enabled;
    // that must be all they do.
    var bm = try Bitmap.init(testing.allocator);
    defer bm.deinit();
    var prng = std.Random.DefaultPrng.init(0x5A1AD);
    const rnd = prng.random();

    var ref = std.ArrayListUnmanaged(u64).empty;
    defer ref.deinit(testing.allocator);
    for (0..5000) |_| {
        const x = rnd.uintLessThan(u64, 1 << 20);
        if (try bm.set(x)) try ref.append(testing.allocator, x);
    }
    std.mem.sort(u64, ref.items, {}, std.sort.asc(u64));

    const got = try bm.toArray(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u64, ref.items, got);
    try testing.expect(bm.counters.sets == 5000);
}

test "the lookup hint never changes what is built" {
    // Two interleaved keys with bursts long enough to repeat containers and
    // values chosen to force growth, relocation, and cleanup mid-stream —
    // each of which moves containers under the keys-node hint that `set`
    // resolves its container through, and must not leave it pointing at a
    // stale answer.
    var bm = try Bitmap.init(testing.allocator);
    defer bm.deinit();
    var ref = std.ArrayListUnmanaged(u64).empty;
    defer ref.deinit(testing.allocator);

    var prng = std.Random.DefaultPrng.init(0xC0_C0A);
    const rnd = prng.random();
    for (0..8) |burst| {
        const key: u64 = (burst % 2) << 16;
        for (0..2000) |_| {
            const x = key | rnd.int(u16);
            if (try bm.set(x)) try ref.append(testing.allocator, x);
        }
    }
    try testing.expect(bm.counters.container_relocs > 0);

    std.mem.sort(u64, ref.items, {}, std.sort.asc(u64));
    const got = try bm.toArray(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u64, ref.items, got);
}

test "compact reports a cleanup" {
    var bm = try Bitmap.init(testing.allocator);
    defer bm.deinit();
    for (0..1000) |i| _ = try bm.set(i * 3);
    const before = bm.counters.cleanups;
    try bm.compact();
    try testing.expectEqual(before + 1, bm.counters.cleanups);
}

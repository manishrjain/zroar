// Copyright 2026 Manish R Jain
// SPDX-License-Identifier: Apache-2.0

//! Test-only helpers shared by more than one test file.
//!
//! Nothing here is reachable from the library: the only path to this file is
//! `src/tests.zig`, so it is never compiled into a zroar build.

const std = @import("std");
const zroar = @import("zroar.zig");
const container = @import("container.zig");

const Bitmap = zroar.Bitmap;
const key_mask = zroar.key_mask;
const testing = std.testing;

/// The reference model: the set of values a bitmap is supposed to hold.
pub const RefSet = std.AutoHashMapUnmanaged(u64, void);

/// Asserts the layout invariants DESIGN.md calls load-bearing, written against
/// the public `keys` and `getContainer` views.
pub fn checkInvariants(bm: *const Bitmap) !void {
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
        try testing.expect(off < bm.data.len);

        const c = bm.getContainer(off);
        try testing.expectEqual(@as(u16, 0), container.size(c) % 4);
        switch (container.getType(c)) {
            // Free-slot invariant: an array container is never observed full.
            .array => try testing.expect(!container.array.isFull(c)),
            .bitmap => {
                try testing.expectEqual(container.max_size, container.size(c));
                try testing.expectEqual(
                    container.getCardinality(c),
                    container.bitmap.cardinality(c),
                );
            },
        }
    }
}

/// A bitmap holding exactly `vals`, in any order.
pub fn testBitmap(vals: []const u64) !Bitmap {
    var bm = try Bitmap.init(testing.allocator);
    errdefer bm.deinit();
    for (vals) |v| _ = try bm.set(v);
    return bm;
}

/// The reference set holding exactly `vals`.
pub fn testRefSet(vals: []const u64) !RefSet {
    var ref = RefSet.empty;
    errdefer ref.deinit(testing.allocator);
    for (vals) |v| try ref.put(testing.allocator, v, {});
    return ref;
}

pub fn refAnd(a: *const RefSet, b: *const RefSet) !RefSet {
    var out = RefSet.empty;
    errdefer out.deinit(testing.allocator);
    var it = a.keyIterator();
    while (it.next()) |k| {
        if (b.contains(k.*)) try out.put(testing.allocator, k.*, {});
    }
    return out;
}

pub fn refAndNot(a: *const RefSet, b: *const RefSet) !RefSet {
    var out = RefSet.empty;
    errdefer out.deinit(testing.allocator);
    var it = a.keyIterator();
    while (it.next()) |k| {
        if (!b.contains(k.*)) try out.put(testing.allocator, k.*, {});
    }
    return out;
}

pub fn refOr(a: *const RefSet, b: *const RefSet) !RefSet {
    var out = RefSet.empty;
    errdefer out.deinit(testing.allocator);
    for ([_]*const RefSet{ a, b }) |set| {
        var it = set.keyIterator();
        while (it.next()) |k| try out.put(testing.allocator, k.*, {});
    }
    return out;
}

/// The fused counts must equal the cardinality of the operation carried out for
/// real: `And` for the intersection, `fastOr` for the union, and a clone put
/// through `andNotInPlace` for the difference. None of the three is symmetric
/// in its operands, so callers check both orders.
pub fn expectFusedCardinalities(a: *const Bitmap, b: *const Bitmap) !void {
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

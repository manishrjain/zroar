//! Unit tests for `container.zig`: the array and bitmap container layouts, the
//! conversion between them, and the two-container set operations.

const std = @import("std");
const container = @import("container.zig");

const testing = std.testing;

// The declarations under test, aliased so the test bodies read as they would
// inside container.zig itself.
const Type = container.Type;
const index_size = container.index_size;
const index_cardinality = container.index_cardinality;
const start_idx = container.start_idx;
const min_size = container.min_size;
const max_array_size = container.max_array_size;
const max_size = container.max_size;
const word_count = container.word_count;
const max_array_values = container.max_array_values;
const max_cardinality = container.max_cardinality;
const invalid_cardinality = container.invalid_cardinality;
const size = container.size;
const getType = container.getType;
const setType = container.setType;
const getCardinality = container.getCardinality;
const setCardinality = container.setCardinality;
const add = container.add;
const has = container.has;
const remove = container.remove;
const minimum = container.minimum;
const maximum = container.maximum;
const zeroOut = container.zeroOut;
const recomputeCardinality = container.recomputeCardinality;
const arraySizeFor = container.arraySizeFor;
const array = container.array;
const bitmap = container.bitmap;
const containerAnd = container.containerAnd;
const containerAndNot = container.containerAndNot;
const containerOr = container.containerOr;

/// Size of an array container for a test that wants to hold exactly `n` values.
/// Tests must not hard-code a size: min_size is adjustable, and at its smallest
/// an array container holds only four values.
fn arraySize(n: usize) u16 {
    return arraySizeFor(n).?;
}

/// Allocates a zeroed, 8-byte-aligned container of `sz` u16s with the
/// header set.
fn testContainer(sz: u16, t: Type) ![]align(8) u16 {
    const c = try testing.allocator.alignedAlloc(u16, .@"8", sz);
    @memset(c, 0);
    c[index_size] = sz;
    setType(c, t);
    return c;
}

test "array add/has/find/remove" {
    const c = try testContainer(arraySize(3), .array);
    defer testing.allocator.free(c);

    try testing.expect(array.add(c, 10));
    try testing.expect(array.add(c, 5));
    try testing.expect(array.add(c, 20));
    try testing.expect(!array.add(c, 10)); // duplicate
    try testing.expectEqual(@as(u32, 3), getCardinality(c));
    try testing.expectEqualSlices(u16, &.{ 5, 10, 20 }, array.values(c));

    try testing.expect(array.has(c, 5));
    try testing.expect(array.has(c, 20));
    try testing.expect(!array.has(c, 6));
    try testing.expect(!array.has(c, 0));
    try testing.expect(!array.has(c, 65535));

    try testing.expectEqual(@as(usize, 0), array.find(c, 0));
    try testing.expectEqual(@as(usize, 1), array.find(c, 6));
    try testing.expectEqual(@as(usize, 3), array.find(c, 21));

    try testing.expect(array.remove(c, 10));
    try testing.expect(!array.remove(c, 10));
    try testing.expectEqualSlices(u16, &.{ 5, 20 }, array.values(c));
    try testing.expectEqual(@as(u16, 5), array.minimum(c));
    try testing.expectEqual(@as(u16, 20), array.maximum(c));
}

test "array boundary values 0 and 0xFFFF" {
    const c = try testContainer(arraySize(2), .array);
    defer testing.allocator.free(c);

    try testing.expect(array.add(c, 0xFFFF));
    try testing.expect(array.add(c, 0));
    try testing.expectEqualSlices(u16, &.{ 0, 0xFFFF }, array.values(c));
    try testing.expect(array.has(c, 0));
    try testing.expect(array.has(c, 0xFFFF));
    try testing.expect(array.remove(c, 0));
    try testing.expect(!array.has(c, 0));
    try testing.expect(array.has(c, 0xFFFF));
}

test "array isFull tracks the free-slot invariant" {
    const c = try testContainer(min_size, .array);
    defer testing.allocator.free(c);

    var i: u16 = 0;
    while (i < min_size - start_idx - 1) : (i += 1) {
        try testing.expect(array.add(c, i));
        try testing.expect(!array.isFull(c));
    }
    try testing.expect(array.add(c, i));
    try testing.expect(array.isFull(c));
}

test "bitmap add/has/remove is LSB-first over u64 words" {
    const c = try testContainer(max_size, .bitmap);
    defer testing.allocator.free(c);

    try testing.expect(bitmap.add(c, 0));
    try testing.expect(!bitmap.add(c, 0));
    try testing.expect(bitmap.add(c, 63));
    try testing.expect(bitmap.add(c, 64));
    try testing.expect(bitmap.add(c, 0xFFFF));
    try testing.expectEqual(@as(u32, 4), getCardinality(c));

    const w = bitmap.words(c);
    try testing.expectEqual(@as(u64, 1) | (@as(u64, 1) << 63), w[0]);
    try testing.expectEqual(@as(u64, 1), w[1]);
    try testing.expectEqual(@as(u64, 1) << 63, w[word_count - 1]);

    try testing.expect(bitmap.has(c, 0));
    try testing.expect(bitmap.has(c, 0xFFFF));
    try testing.expect(!bitmap.has(c, 1));
    try testing.expectEqual(@as(u16, 0), bitmap.minimum(c));
    try testing.expectEqual(@as(u16, 0xFFFF), bitmap.maximum(c));

    try testing.expect(bitmap.remove(c, 0));
    try testing.expect(!bitmap.remove(c, 0));
    try testing.expectEqual(@as(u32, 3), getCardinality(c));
    try testing.expectEqual(@as(u16, 63), bitmap.minimum(c));
    try testing.expectEqual(getCardinality(c), bitmap.cardinality(c));
}

test "array to bitmap conversion preserves membership" {
    const c = try testContainer(max_size, .array);
    defer testing.allocator.free(c);

    // Values chosen so some land in low words and some in high words,
    // which is exactly the case an in-place conversion without a scratch
    // copy would break.
    var expected: [max_array_values]u16 = undefined;
    var i: usize = 0;
    while (i < max_array_values) : (i += 1) {
        expected[i] = @intCast(i * 32);
        try testing.expect(array.add(c, expected[i]));
    }
    try testing.expectEqual(@as(u32, max_array_values), getCardinality(c));

    array.toBitmap(c);

    try testing.expectEqual(Type.bitmap, getType(c));
    try testing.expectEqual(@as(u32, max_array_values), getCardinality(c));
    try testing.expectEqual(getCardinality(c), bitmap.cardinality(c));
    for (expected) |v| try testing.expect(bitmap.has(c, v));
    try testing.expect(!bitmap.has(c, 1));
    try testing.expectEqual(@as(u16, 0), bitmap.minimum(c));
    try testing.expectEqual(expected[max_array_values - 1], bitmap.maximum(c));
}

test "dispatching add/has/remove by container type" {
    const a = try testContainer(min_size, .array);
    defer testing.allocator.free(a);
    const b = try testContainer(max_size, .bitmap);
    defer testing.allocator.free(b);

    for ([_][]u16{ a, b }) |c| {
        try testing.expect(add(c, 42));
        try testing.expect(has(c, 42));
        try testing.expect(!has(c, 43));
        try testing.expectEqual(@as(u16, 42), minimum(c));
        try testing.expectEqual(@as(u16, 42), maximum(c));
        try testing.expect(remove(c, 42));
        try testing.expect(!has(c, 42));
        try testing.expectEqual(@as(u32, 0), getCardinality(c));
    }
}

test "cardinality header is a u32 spanning both header slots" {
    const c = try testContainer(min_size, .array);
    defer testing.allocator.free(c);

    setCardinality(c, 65535);
    try testing.expectEqual(@as(u32, 65535), getCardinality(c));
    // 65536 does not fit in one u16, so it must spill into the second slot.
    setCardinality(c, max_cardinality);
    try testing.expectEqual(@as(u32, max_cardinality), getCardinality(c));
    try testing.expectEqual(
        @as(u16, 1),
        c[index_cardinality] | c[index_cardinality + 1],
    );
    setCardinality(c, invalid_cardinality);
    try testing.expectEqual(invalid_cardinality, getCardinality(c));
    setCardinality(c, 0);
    try testing.expectEqual(@as(u32, 0), getCardinality(c));
    try testing.expectEqual(@as(u16, 0), c[index_cardinality]);
    try testing.expectEqual(@as(u16, 0), c[index_cardinality + 1]);
}

/// Fills a container with `vals` (which must fit).
fn fill(c: []u16, vals: []const u16) void {
    for (vals) |v| _ = add(c, v);
}

/// Every value of a container, ascending, whatever its type. Lets a test
/// compare results without caring which representation was chosen.
fn collect(c: []const u16, out: []u16) []u16 {
    var n: usize = 0;
    switch (getType(c)) {
        .array => for (array.values(c)) |v| {
            out[n] = v;
            n += 1;
        },
        .bitmap => for (bitmap.constWords(c), 0..) |word, i| {
            var w = word;
            while (w != 0) : (w &= w - 1) {
                out[n] = @intCast(i * 64 + @ctz(w));
                n += 1;
            }
        },
    }
    return out[0..n];
}

test "containerAnd over all four container type pairs" {
    var out: [max_cardinality]u16 = undefined;
    const left = [_]u16{ 1, 3, 5, 7, 9, 64, 65, 4096 };
    const right = [_]u16{ 3, 4, 5, 9, 65, 4095, 4096 };
    const expected = [_]u16{ 3, 5, 9, 65, 4096 };

    for ([_]Type{ .array, .bitmap }) |dt| {
        for ([_]Type{ .array, .bitmap }) |st| {
            const a_size = if (dt == .array) arraySize(left.len) else max_size;
            const a = try testContainer(a_size, dt);
            defer testing.allocator.free(a);
            const b_size = if (st == .array) arraySize(right.len) else max_size;
            const b = try testContainer(b_size, st);
            defer testing.allocator.free(b);
            fill(a, &left);
            fill(b, &right);

            containerAnd(a, b);
            // A bitmap container is never demoted back to an array.
            try testing.expectEqual(dt, getType(a));
            try testing.expectEqualSlices(u16, &expected, collect(a, &out));
            try testing.expectEqual(@as(u32, expected.len), getCardinality(a));
        }
    }
}

test "containerAnd emptying the container" {
    var out: [max_cardinality]u16 = undefined;
    for ([_]Type{ .array, .bitmap }) |dt| {
        for ([_]Type{ .array, .bitmap }) |st| {
            const a_size = if (dt == .array) arraySize(3) else max_size;
            const a = try testContainer(a_size, dt);
            defer testing.allocator.free(a);
            const b_size = if (st == .array) arraySize(3) else max_size;
            const b = try testContainer(b_size, st);
            defer testing.allocator.free(b);
            fill(a, &.{ 1, 2, 3 });
            fill(b, &.{ 4, 5, 6 });

            containerAnd(a, b);
            try testing.expectEqual(@as(u32, 0), getCardinality(a));
            try testing.expectEqual(@as(usize, 0), collect(a, &out).len);
            if (dt == .bitmap) {
                try testing.expectEqual(@as(u32, 0), bitmap.cardinality(a));
            }
            // An emptied array container must not keep stale values around.
            if (dt == .array) {
                try testing.expectEqual(@as(u16, 0), a[start_idx]);
            }
        }
    }
}

test "containerAnd of two arrays takes the galloping path in both directions" {
    // 64x skew is where intersection2by2 switches to galloping, and there the
    // buffer it writes into aliases the container it reads as the large set.
    var out: [max_cardinality]u16 = undefined;
    const large = try testContainer(max_array_size, .array);
    defer testing.allocator.free(large);
    const small = try testContainer(arraySize(4), .array);
    defer testing.allocator.free(small);

    var i: u16 = 0;
    while (i < 1000) : (i += 1) _ = array.add(large, i * 3);
    fill(small, &.{ 0, 1, 3, 2997 });
    const expected = [_]u16{ 0, 3, 2997 };

    const copy = try testing.allocator.alignedAlloc(u16, .@"8", max_array_size);
    defer testing.allocator.free(copy);
    @memcpy(copy, large);

    containerAnd(large, small); // dst is the large side
    try testing.expectEqualSlices(u16, &expected, collect(large, &out));

    containerAnd(small, copy); // dst is the small side
    try testing.expectEqualSlices(u16, &expected, collect(small, &out));
}

test "containerAndNot over all four container type pairs" {
    var out: [max_cardinality]u16 = undefined;
    const left = [_]u16{ 1, 3, 5, 7, 9, 64, 65, 4096 };
    const right = [_]u16{ 3, 4, 5, 9, 65, 4095, 4096 };
    const expected = [_]u16{ 1, 7, 64 };

    for ([_]Type{ .array, .bitmap }) |dt| {
        for ([_]Type{ .array, .bitmap }) |st| {
            const a_size = if (dt == .array) arraySize(left.len) else max_size;
            const a = try testContainer(a_size, dt);
            defer testing.allocator.free(a);
            const b_size = if (st == .array) arraySize(right.len) else max_size;
            const b = try testContainer(b_size, st);
            defer testing.allocator.free(b);
            fill(a, &left);
            fill(b, &right);

            containerAndNot(a, b);
            try testing.expectEqual(dt, getType(a));
            try testing.expectEqualSlices(u16, &expected, collect(a, &out));
            try testing.expectEqual(@as(u32, expected.len), getCardinality(a));

            // Subtracting itself empties the container.
            containerAndNot(a, a);
            try testing.expectEqual(@as(u32, 0), getCardinality(a));
            try testing.expectEqual(@as(usize, 0), collect(a, &out).len);
        }
    }
}

test "containerOr unions in place when the destination is a bitmap" {
    var out: [max_cardinality]u16 = undefined;
    const buf = try testing.allocator.alignedAlloc(u16, .@"8", max_size);
    defer testing.allocator.free(buf);

    for ([_]Type{ .array, .bitmap }) |st| {
        const a = try testContainer(max_size, .bitmap);
        defer testing.allocator.free(a);
        // Four values: three now and one more further down.
        const b_size = if (st == .array) arraySize(4) else max_size;
        const b = try testContainer(b_size, st);
        defer testing.allocator.free(b);
        fill(a, &.{ 1, 2, 65535 });
        fill(b, &.{ 2, 3, 64 });

        const eager = containerOr(a, b, buf, false);
        try testing.expectEqual(@as(?[]u16, null), eager);
        const got = collect(a, &out);
        try testing.expectEqualSlices(u16, &.{ 1, 2, 3, 64, 65535 }, got);
        try testing.expectEqual(@as(u32, 5), getCardinality(a));

        // Lazy mode defers the recount to the caller.
        fill(b, &.{7});
        const lazily = containerOr(a, b, buf, true);
        try testing.expectEqual(@as(?[]u16, null), lazily);
        try testing.expectEqual(invalid_cardinality, getCardinality(a));
        recomputeCardinality(a);
        try testing.expectEqual(@as(u32, 6), getCardinality(a));
    }
}

test "containerOr of two arrays keeps a free slot and grows to a bitmap" {
    var out: [max_cardinality]u16 = undefined;
    const buf = try testing.allocator.alignedAlloc(u16, .@"8", max_size);
    defer testing.allocator.free(buf);

    const a = try testContainer(arraySize(3), .array);
    defer testing.allocator.free(a);
    const b = try testContainer(arraySize(3), .array);
    defer testing.allocator.free(b);
    fill(a, &.{ 1, 3, 5 });
    fill(b, &.{ 2, 3, 9 });

    const small = containerOr(a, b, buf, false).?;
    try testing.expectEqual(Type.array, getType(small));
    const got = collect(small, &out);
    try testing.expectEqualSlices(u16, &.{ 1, 2, 3, 5, 9 }, got);
    // sroar can emit an exactly full array container here (Go bug 4).
    try testing.expect(!array.isFull(small));
    try testing.expectEqual(@as(u16, 0), size(small) % 4);
    try testing.expectEqual(@as(usize, size(small)), small.len);

    // The largest union an array container can still hold is one value short of
    // filling it; one more value and the result has to become a bitmap.
    const limit = max_array_values - 1;
    const big_a = try testContainer(max_array_size, .array);
    defer testing.allocator.free(big_a);
    const big_b = try testContainer(arraySize(2), .array);
    defer testing.allocator.free(big_b);
    var i: u16 = 0;
    while (i < limit - 1) : (i += 1) _ = array.add(big_a, i);
    _ = array.add(big_b, 40000);

    const fits = containerOr(big_a, big_b, buf, false).?;
    try testing.expectEqual(Type.array, getType(fits));
    try testing.expectEqual(@as(u32, limit), getCardinality(fits));
    try testing.expectEqual(@as(u16, max_array_size), size(fits));
    try testing.expect(!array.isFull(fits));

    _ = array.add(big_b, 40001);
    const grown = containerOr(big_a, big_b, buf, false).?;
    try testing.expectEqual(Type.bitmap, getType(grown));
    try testing.expectEqual(@as(u32, limit + 1), getCardinality(grown));
    try testing.expectEqual(@as(usize, limit + 1), collect(grown, &out).len);
}

test "containerOr of an array with a bitmap yields a bitmap" {
    var out: [max_cardinality]u16 = undefined;
    const buf = try testing.allocator.alignedAlloc(u16, .@"8", max_size);
    defer testing.allocator.free(buf);

    const a = try testContainer(arraySize(3), .array);
    defer testing.allocator.free(a);
    const b = try testContainer(max_size, .bitmap);
    defer testing.allocator.free(b);
    fill(a, &.{ 1, 70, 65535 });
    fill(b, &.{ 2, 70 });

    const res = containerOr(a, b, buf, false).?;
    try testing.expectEqual(Type.bitmap, getType(res));
    try testing.expectEqual(@as(usize, max_size), res.len);
    const got = collect(res, &out);
    try testing.expectEqualSlices(u16, &.{ 1, 2, 70, 65535 }, got);
    try testing.expectEqual(@as(u32, 4), getCardinality(res));
    // The array operand is only read, never rewritten.
    try testing.expectEqual(@as(u32, 3), getCardinality(a));
}

test "zeroOut and arraySizeFor" {
    const a = try testContainer(arraySize(3), .array);
    defer testing.allocator.free(a);
    const b = try testContainer(max_size, .bitmap);
    defer testing.allocator.free(b);
    fill(a, &.{ 1, 2, 3 });
    fill(b, &.{ 1, 2, 3 });

    zeroOut(a);
    try testing.expectEqual(@as(u32, 0), getCardinality(a));
    try testing.expectEqual(@as(u16, 0), a[start_idx]);
    zeroOut(b);
    try testing.expectEqual(@as(u32, 0), getCardinality(b));
    try testing.expectEqual(@as(u32, 0), bitmap.cardinality(b));

    try testing.expectEqual(@as(?u16, min_size), arraySizeFor(0));
    // The last count the smallest container holds, and the first that steps up.
    try testing.expectEqual(
        @as(?u16, min_size),
        arraySizeFor(min_size - start_idx - 1),
    );
    try testing.expectEqual(
        @as(?u16, min_size * 2),
        arraySizeFor(min_size - start_idx),
    );
    try testing.expectEqual(
        @as(?u16, max_array_size),
        arraySizeFor(max_array_values - 1),
    );
    // 2044 values would leave an array container exactly full.
    try testing.expectEqual(@as(?u16, null), arraySizeFor(max_array_values));
}

test "container sizes obey the multiple-of-4 alignment invariant" {
    try testing.expectEqual(@as(u16, 0), min_size % 4);
    try testing.expectEqual(@as(u16, 0), max_array_size % 4);
    try testing.expectEqual(@as(u16, 0), max_size % 4);
    try testing.expectEqual(@as(u16, 4100), max_size);
    try testing.expectEqual(@as(usize, 1024), word_count);
    var sz: u16 = min_size;
    while (sz < max_array_size) : (sz *= 2) {
        try testing.expectEqual(@as(u16, 0), sz % 4);
    }
}

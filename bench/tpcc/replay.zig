//! Replay a neutral TPC-C-derived bitmap-index trace through zroar and
//! CRoaring's roaring64 implementation.

const std = @import("std");
const zroar = @import("zroar");
const roaring64 = @import("roaring64");
const model = @import("model.zig");

const Allocator = std.mem.Allocator;
const Bitmap = zroar.Bitmap;
const Bitmap64 = roaring64.Bitmap64;

const Profile = enum { resident, serialized };
const Workload = enum { read, write };

const ZEntry = struct {
    ref: model.ListRef,
    data: union(Profile) {
        resident: Bitmap,
        serialized: []align(8) u8,
    },
};

const ZState = struct {
    allocator: Allocator,
    profile: Profile,
    map: std.AutoHashMap(u128, usize),
    entries: std.ArrayListUnmanaged(ZEntry) = .empty,
    bytes_rewritten: u64 = 0,

    fn init(allocator: Allocator, fixture: *const model.Fixture, profile: Profile) !ZState {
        var self = ZState{
            .allocator = allocator,
            .profile = profile,
            .map = std.AutoHashMap(u128, usize).init(allocator),
        };
        errdefer self.deinit();
        try self.entries.ensureTotalCapacity(allocator, fixture.postings.len);
        try self.map.ensureTotalCapacity(@intCast(fixture.postings.len));
        for (fixture.postings) |posting| {
            var bitmap = try Bitmap.init(allocator);
            errdefer bitmap.deinit();
            for (posting.keys) |key| _ = try bitmap.set(key);
            const data: @FieldType(ZEntry, "data") = switch (profile) {
                .resident => .{ .resident = bitmap },
                .serialized => blk: {
                    const buffer = try bitmap.toBufferCopy(allocator);
                    bitmap.deinit();
                    break :blk .{ .serialized = buffer };
                },
            };
            const index = self.entries.items.len;
            self.entries.appendAssumeCapacity(.{ .ref = posting.ref, .data = data });
            self.map.putAssumeCapacity(posting.ref.mapKey(), index);
        }
        return self;
    }

    fn deinit(self: *ZState) void {
        for (self.entries.items) |*entry| switch (entry.data) {
            .resident => |*bitmap| bitmap.deinit(),
            .serialized => |buffer| self.allocator.free(buffer),
        };
        self.entries.deinit(self.allocator);
        self.map.deinit();
    }

    fn get(self: *ZState, list_ref: model.ListRef) ?*ZEntry {
        const index = self.map.get(list_ref.mapKey()) orelse return null;
        return &self.entries.items[index];
    }

    fn getOrCreate(self: *ZState, list_ref: model.ListRef) !*ZEntry {
        if (self.get(list_ref)) |entry| return entry;
        var bitmap = try Bitmap.init(self.allocator);
        const data: @FieldType(ZEntry, "data") = switch (self.profile) {
            .resident => .{ .resident = bitmap },
            .serialized => blk: {
                const buffer = bitmap.toBufferCopy(self.allocator) catch |err| {
                    bitmap.deinit();
                    return err;
                };
                bitmap.deinit();
                break :blk .{ .serialized = buffer };
            },
        };
        const index = self.entries.items.len;
        try self.entries.append(self.allocator, .{ .ref = list_ref, .data = data });
        errdefer {
            var removed = self.entries.pop().?;
            switch (removed.data) {
                .resident => |*value| value.deinit(),
                .serialized => |buffer| self.allocator.free(buffer),
            }
        }
        try self.map.put(list_ref.mapKey(), index);
        return &self.entries.items[index];
    }

    fn cardinality(self: *ZState, list_ref: model.ListRef) !u64 {
        const entry = self.get(list_ref) orelse return 0;
        return switch (entry.data) {
            .resident => |*bitmap| bitmap.getCardinality(),
            .serialized => |buffer| blk: {
                var bitmap = try Bitmap.fromBuffer(self.allocator, buffer);
                defer bitmap.deinit();
                break :blk bitmap.getCardinality();
            },
        };
    }

    fn probe(self: *ZState, list_ref: model.ListRef, key: u64) !u64 {
        const entry = self.get(list_ref) orelse return 0;
        return switch (entry.data) {
            .resident => |*bitmap| @intFromBool(bitmap.contains(key)),
            .serialized => |buffer| blk: {
                var bitmap = try Bitmap.fromBuffer(self.allocator, buffer);
                defer bitmap.deinit();
                break :blk @intFromBool(bitmap.contains(key));
            },
        };
    }

    fn setCardinality(self: *ZState, a_ref: model.ListRef, b_ref: model.ListRef, is_union: bool) !u64 {
        const a = self.get(a_ref);
        const b = self.get(b_ref);
        if (a == null) return if (is_union) try self.cardinality(b_ref) else 0;
        if (b == null) return if (is_union) try self.cardinality(a_ref) else 0;
        return switch (self.profile) {
            .resident => if (is_union)
                a.?.data.resident.orCardinality(&b.?.data.resident)
            else
                a.?.data.resident.andCardinality(&b.?.data.resident),
            .serialized => blk: {
                var ab = try Bitmap.fromBuffer(self.allocator, a.?.data.serialized);
                defer ab.deinit();
                var bb = try Bitmap.fromBuffer(self.allocator, b.?.data.serialized);
                defer bb.deinit();
                break :blk if (is_union) ab.orCardinality(&bb) else ab.andCardinality(&bb);
            },
        };
    }

    fn mutate(self: *ZState, list_ref: model.ListRef, key: u64, insert: bool) !bool {
        const entry = try self.getOrCreate(list_ref);
        return switch (entry.data) {
            .resident => |*bitmap| if (insert) try bitmap.set(key) else bitmap.remove(key),
            .serialized => |old_buffer| blk: {
                var bitmap = try Bitmap.fromBufferCopy(self.allocator, old_buffer);
                defer bitmap.deinit();
                const changed = if (insert) try bitmap.set(key) else bitmap.remove(key);
                const new_buffer = try bitmap.toBufferCopy(self.allocator);
                self.allocator.free(old_buffer);
                entry.data.serialized = new_buffer;
                self.bytes_rewritten += new_buffer.len;
                break :blk changed;
            },
        };
    }

    fn execute(self: *ZState, op: model.Op) !u64 {
        return switch (op.tag) {
            .probe => self.probe(op.a, op.key),
            .intersect => self.setCardinality(op.a, op.b, false),
            .union_cardinality => self.setCardinality(op.a, op.b, true),
            .insert => @intFromBool(try self.mutate(op.a, op.key, true)),
            .remove => @intFromBool(try self.mutate(op.a, op.key, false)),
            .move => blk: {
                const removed = try self.mutate(op.a, op.key, false);
                const added = try self.mutate(op.b, op.key, true);
                break :blk @as(u64, @intFromBool(removed)) | (@as(u64, @intFromBool(added)) << 1);
            },
        };
    }

    fn serializedBytes(self: *const ZState) u64 {
        if (self.profile == .resident) return 0;
        var total: u64 = 0;
        for (self.entries.items) |entry| total += entry.data.serialized.len;
        return total;
    }

    fn digest(self: *ZState) !u64 {
        const order = try sortedEntryOrder(ZEntry, self.allocator, self.entries.items);
        defer self.allocator.free(order);
        var hash: u64 = model.fnv_offset;
        for (order) |index| {
            const entry = &self.entries.items[index];
            model.hashU64(&hash, @intFromEnum(entry.ref.index));
            model.hashU64(&hash, entry.ref.value);
            switch (entry.data) {
                .resident => |*bitmap| {
                    model.hashU64(&hash, bitmap.getCardinality());
                    var it = bitmap.iterator();
                    while (it.next()) |key| model.hashU64(&hash, key);
                },
                .serialized => |buffer| {
                    var bitmap = try Bitmap.fromBuffer(self.allocator, buffer);
                    defer bitmap.deinit();
                    model.hashU64(&hash, bitmap.getCardinality());
                    var it = bitmap.iterator();
                    while (it.next()) |key| model.hashU64(&hash, key);
                },
            }
        }
        return hash;
    }
};

const REntry = struct {
    ref: model.ListRef,
    data: union(Profile) {
        resident: *Bitmap64,
        serialized: []u8,
    },
};

const RState = struct {
    allocator: Allocator,
    profile: Profile,
    map: std.AutoHashMap(u128, usize),
    entries: std.ArrayListUnmanaged(REntry) = .empty,
    bytes_rewritten: u64 = 0,

    fn init(allocator: Allocator, fixture: *const model.Fixture, profile: Profile) !RState {
        var self = RState{
            .allocator = allocator,
            .profile = profile,
            .map = std.AutoHashMap(u128, usize).init(allocator),
        };
        errdefer self.deinit();
        try self.entries.ensureTotalCapacity(allocator, fixture.postings.len);
        try self.map.ensureTotalCapacity(@intCast(fixture.postings.len));
        for (fixture.postings) |posting| {
            const bitmap = try Bitmap64.create();
            errdefer bitmap.free();
            for (posting.keys) |key| _ = bitmap.addChecked(key);
            _ = bitmap.runOptimize();
            const data: @FieldType(REntry, "data") = switch (profile) {
                .resident => .{ .resident = bitmap },
                .serialized => blk: {
                    const buffer = try allocator.alloc(u8, bitmap.portableSizeInBytes());
                    _ = bitmap.portableSerialize(buffer);
                    bitmap.free();
                    break :blk .{ .serialized = buffer };
                },
            };
            const index = self.entries.items.len;
            self.entries.appendAssumeCapacity(.{ .ref = posting.ref, .data = data });
            self.map.putAssumeCapacity(posting.ref.mapKey(), index);
        }
        return self;
    }

    fn deinit(self: *RState) void {
        for (self.entries.items) |entry| switch (entry.data) {
            .resident => |bitmap| bitmap.free(),
            .serialized => |buffer| self.allocator.free(buffer),
        };
        self.entries.deinit(self.allocator);
        self.map.deinit();
    }

    fn get(self: *RState, list_ref: model.ListRef) ?*REntry {
        const index = self.map.get(list_ref.mapKey()) orelse return null;
        return &self.entries.items[index];
    }

    fn getOrCreate(self: *RState, list_ref: model.ListRef) !*REntry {
        if (self.get(list_ref)) |entry| return entry;
        const bitmap = try Bitmap64.create();
        const data: @FieldType(REntry, "data") = switch (self.profile) {
            .resident => .{ .resident = bitmap },
            .serialized => blk: {
                const buffer = self.allocator.alloc(u8, bitmap.portableSizeInBytes()) catch |err| {
                    bitmap.free();
                    return err;
                };
                _ = bitmap.portableSerialize(buffer);
                bitmap.free();
                break :blk .{ .serialized = buffer };
            },
        };
        const index = self.entries.items.len;
        try self.entries.append(self.allocator, .{ .ref = list_ref, .data = data });
        errdefer {
            const removed = self.entries.pop().?;
            switch (removed.data) {
                .resident => |value| value.free(),
                .serialized => |buffer| self.allocator.free(buffer),
            }
        }
        try self.map.put(list_ref.mapKey(), index);
        return &self.entries.items[index];
    }

    fn cardinality(self: *RState, list_ref: model.ListRef) !u64 {
        const entry = self.get(list_ref) orelse return 0;
        return switch (entry.data) {
            .resident => |bitmap| bitmap.cardinality(),
            .serialized => |buffer| blk: {
                const bitmap = try Bitmap64.portableDeserializeSafe(buffer);
                defer bitmap.free();
                break :blk bitmap.cardinality();
            },
        };
    }

    fn probe(self: *RState, list_ref: model.ListRef, key: u64) !u64 {
        const entry = self.get(list_ref) orelse return 0;
        return switch (entry.data) {
            .resident => |bitmap| @intFromBool(bitmap.contains(key)),
            .serialized => |buffer| blk: {
                const bitmap = try Bitmap64.portableDeserializeSafe(buffer);
                defer bitmap.free();
                break :blk @intFromBool(bitmap.contains(key));
            },
        };
    }

    fn setCardinality(self: *RState, a_ref: model.ListRef, b_ref: model.ListRef, is_union: bool) !u64 {
        const a = self.get(a_ref);
        const b = self.get(b_ref);
        if (a == null) return if (is_union) try self.cardinality(b_ref) else 0;
        if (b == null) return if (is_union) try self.cardinality(a_ref) else 0;
        return switch (self.profile) {
            .resident => if (is_union)
                Bitmap64._orCardinality(a.?.data.resident, b.?.data.resident)
            else
                Bitmap64._andCardinality(a.?.data.resident, b.?.data.resident),
            .serialized => blk: {
                const ab = try Bitmap64.portableDeserializeSafe(a.?.data.serialized);
                defer ab.free();
                const bb = try Bitmap64.portableDeserializeSafe(b.?.data.serialized);
                defer bb.free();
                break :blk if (is_union) Bitmap64._orCardinality(ab, bb) else Bitmap64._andCardinality(ab, bb);
            },
        };
    }

    fn mutate(self: *RState, list_ref: model.ListRef, key: u64, insert: bool) !bool {
        const entry = try self.getOrCreate(list_ref);
        return switch (entry.data) {
            .resident => |bitmap| if (insert) bitmap.addChecked(key) else bitmap.removeChecked(key),
            .serialized => |old_buffer| blk: {
                const bitmap = try Bitmap64.portableDeserializeSafe(old_buffer);
                defer bitmap.free();
                const changed = if (insert) bitmap.addChecked(key) else bitmap.removeChecked(key);
                const new_buffer = try self.allocator.alloc(u8, bitmap.portableSizeInBytes());
                _ = bitmap.portableSerialize(new_buffer);
                self.allocator.free(old_buffer);
                entry.data.serialized = new_buffer;
                self.bytes_rewritten += new_buffer.len;
                break :blk changed;
            },
        };
    }

    fn execute(self: *RState, op: model.Op) !u64 {
        return switch (op.tag) {
            .probe => self.probe(op.a, op.key),
            .intersect => self.setCardinality(op.a, op.b, false),
            .union_cardinality => self.setCardinality(op.a, op.b, true),
            .insert => @intFromBool(try self.mutate(op.a, op.key, true)),
            .remove => @intFromBool(try self.mutate(op.a, op.key, false)),
            .move => blk: {
                const removed = try self.mutate(op.a, op.key, false);
                const added = try self.mutate(op.b, op.key, true);
                break :blk @as(u64, @intFromBool(removed)) | (@as(u64, @intFromBool(added)) << 1);
            },
        };
    }

    fn serializedBytes(self: *const RState) u64 {
        if (self.profile == .resident) return 0;
        var total: u64 = 0;
        for (self.entries.items) |entry| total += entry.data.serialized.len;
        return total;
    }

    fn digest(self: *RState) !u64 {
        const order = try sortedEntryOrder(REntry, self.allocator, self.entries.items);
        defer self.allocator.free(order);
        var hash: u64 = model.fnv_offset;
        for (order) |index| {
            const entry = &self.entries.items[index];
            model.hashU64(&hash, @intFromEnum(entry.ref.index));
            model.hashU64(&hash, entry.ref.value);
            switch (entry.data) {
                .resident => |bitmap| try hashRBitmap(&hash, bitmap),
                .serialized => |buffer| {
                    const bitmap = try Bitmap64.portableDeserializeSafe(buffer);
                    defer bitmap.free();
                    try hashRBitmap(&hash, bitmap);
                },
            }
        }
        return hash;
    }
};

fn hashRBitmap(hash: *u64, bitmap: *const Bitmap64) !void {
    model.hashU64(hash, bitmap.cardinality());
    var it = try bitmap.iterator();
    defer it.free();
    while (it.next()) |key| model.hashU64(hash, key);
}

fn sortedEntryOrder(comptime Entry: type, allocator: Allocator, entries: []const Entry) ![]usize {
    const order = try allocator.alloc(usize, entries.len);
    for (order, 0..) |*value, i| value.* = i;
    std.mem.sortUnstable(usize, order, entries, struct {
        fn less(context: []const Entry, a: usize, b: usize) bool {
            const ar = context[a].ref;
            const br = context[b].ref;
            const ai = @intFromEnum(ar.index);
            const bi = @intFromEnum(br.index);
            return ai < bi or (ai == bi and ar.value < br.value);
        }
    }.less);
    return order;
}

const RunResult = struct {
    total_ns: u64,
    build_ns: u64,
    initial_serialized_bytes: u64,
    bytes_rewritten: u64,
    latencies: [5]std.ArrayListUnmanaged(u64) = .{ .empty, .empty, .empty, .empty, .empty },

    fn deinit(self: *RunResult, allocator: Allocator) void {
        for (&self.latencies) |*values| values.deinit(allocator);
    }
};

fn runOnce(
    comptime StateType: type,
    io: std.Io,
    allocator: Allocator,
    fixture: *const model.Fixture,
    trace: *const model.LoadedTrace,
    profile: Profile,
    capture_latencies: bool,
) !RunResult {
    const build_start = std.Io.Clock.Timestamp.now(io, .awake);
    var state = try StateType.init(allocator, fixture, profile);
    defer state.deinit();
    const build_ns: u64 = @intCast(build_start.untilNow(io).raw.toNanoseconds());
    var result = RunResult{
        .total_ns = 0,
        .build_ns = build_ns,
        .initial_serialized_bytes = state.serializedBytes(),
        .bytes_rewritten = 0,
    };
    errdefer result.deinit(allocator);
    const run_start = std.Io.Clock.Timestamp.now(io, .awake);
    for (trace.txns, 0..) |txn, txn_index| {
        const txn_start = if (capture_latencies) std.Io.Clock.Timestamp.now(io, .awake) else undefined;
        const first: usize = @intCast(txn.first_op);
        for (trace.ops[first..][0..txn.op_count], 0..) |op, op_offset| {
            const actual = try state.execute(op);
            if (actual != op.expected) {
                std.debug.print("replay mismatch at txn {d}, op {d} ({s}): expected {d}, got {d}\n", .{
                    txn_index,
                    op_offset,
                    @tagName(op.tag),
                    op.expected,
                    actual,
                });
                return error.ReplayMismatch;
            }
        }
        if (capture_latencies) {
            const elapsed: u64 = @intCast(txn_start.untilNow(io).raw.toNanoseconds());
            try result.latencies[@intFromEnum(txn.kind)].append(allocator, elapsed);
        }
    }
    result.total_ns = @intCast(run_start.untilNow(io).raw.toNanoseconds());
    result.bytes_rewritten = state.bytes_rewritten;
    const digest = try state.digest();
    if (digest != trace.expected_final_digest) {
        std.debug.print("final digest mismatch: expected {x:0>16}, got {x:0>16}\n", .{ trace.expected_final_digest, digest });
        return error.FinalDigestMismatch;
    }
    return result;
}

const Summary = struct {
    layout: model.Layout,
    profile: Profile,
    workload: Workload,
    z_ns_per_txn: f64,
    r_ns_per_txn: f64,
};

fn printSummary(summaries: []const Summary) void {
    if (summaries.len == 0) return;
    std.debug.print("\nComparison summary\n", .{});
    std.debug.print("  {s:<12}{s:<12}{s:<13}{s:>14}{s:>14}  {s}\n", .{ "layout", "workload", "profile", "zroar ns/txn", "CR ns/txn", "winner" });
    for (summaries) |summary| {
        const z = summary.z_ns_per_txn;
        const r = summary.r_ns_per_txn;
        if (z < r) {
            std.debug.print("  {s:<12}{s:<12}{s:<13}{d:14.0}{d:14.0}  zroar {d:.2}x faster\n", .{
                summary.layout.name(), @tagName(summary.workload), @tagName(summary.profile), z, r, r / z,
            });
        } else if (r < z) {
            std.debug.print("  {s:<12}{s:<12}{s:<13}{d:14.0}{d:14.0}  CRoaring {d:.2}x faster\n", .{
                summary.layout.name(), @tagName(summary.workload), @tagName(summary.profile), z, r, z / r,
            });
        } else {
            std.debug.print("  {s:<12}{s:<12}{s:<13}{d:14.0}{d:14.0}  tie\n", .{
                summary.layout.name(), @tagName(summary.workload), @tagName(summary.profile), z, r,
            });
        }
    }
}

const Measurement = struct {
    allocator: Allocator,
    median_total_ns: u64,
    median_build_ns: u64,
    initial_serialized_bytes: u64,
    bytes_rewritten: u64,
    latencies: [5]std.ArrayListUnmanaged(u64),

    fn deinit(self: *Measurement) void {
        for (&self.latencies) |*values| values.deinit(self.allocator);
    }
};

const PairMeasurement = struct { z: Measurement, r: Measurement };

/// Interleave library runs so temperature, frequency scaling, and transient
/// host load are not consistently assigned to one implementation.
fn measurePair(
    io: std.Io,
    allocator: Allocator,
    fixture: *const model.Fixture,
    trace: *const model.LoadedTrace,
    profile: Profile,
    samples: usize,
    z_first: bool,
) !PairMeasurement {
    var z_warmup = try runOnce(ZState, io, allocator, fixture, trace, profile, false);
    z_warmup.deinit(allocator);
    var r_warmup = try runOnce(RState, io, allocator, fixture, trace, profile, false);
    r_warmup.deinit(allocator);
    const z_totals = try allocator.alloc(u64, samples);
    defer allocator.free(z_totals);
    const z_builds = try allocator.alloc(u64, samples);
    defer allocator.free(z_builds);
    const r_totals = try allocator.alloc(u64, samples);
    defer allocator.free(r_totals);
    const r_builds = try allocator.alloc(u64, samples);
    defer allocator.free(r_builds);
    var last_z: RunResult = undefined;
    var last_r: RunResult = undefined;
    for (0..samples) |sample| {
        const capture = sample + 1 == samples;
        const this_z_first = if (sample % 2 == 0) z_first else !z_first;
        if (this_z_first) {
            var z_run = try runOnce(ZState, io, allocator, fixture, trace, profile, capture);
            z_totals[sample] = z_run.total_ns;
            z_builds[sample] = z_run.build_ns;
            if (capture) last_z = z_run else z_run.deinit(allocator);
            var r_run = try runOnce(RState, io, allocator, fixture, trace, profile, capture);
            r_totals[sample] = r_run.total_ns;
            r_builds[sample] = r_run.build_ns;
            if (capture) last_r = r_run else r_run.deinit(allocator);
        } else {
            var r_run = try runOnce(RState, io, allocator, fixture, trace, profile, capture);
            r_totals[sample] = r_run.total_ns;
            r_builds[sample] = r_run.build_ns;
            if (capture) last_r = r_run else r_run.deinit(allocator);
            var z_run = try runOnce(ZState, io, allocator, fixture, trace, profile, capture);
            z_totals[sample] = z_run.total_ns;
            z_builds[sample] = z_run.build_ns;
            if (capture) last_z = z_run else z_run.deinit(allocator);
        }
    }
    std.mem.sortUnstable(u64, z_totals, {}, comptime std.sort.asc(u64));
    std.mem.sortUnstable(u64, z_builds, {}, comptime std.sort.asc(u64));
    std.mem.sortUnstable(u64, r_totals, {}, comptime std.sort.asc(u64));
    std.mem.sortUnstable(u64, r_builds, {}, comptime std.sort.asc(u64));
    return .{
        .z = .{
            .allocator = allocator,
            .median_total_ns = z_totals[z_totals.len / 2],
            .median_build_ns = z_builds[z_builds.len / 2],
            .initial_serialized_bytes = last_z.initial_serialized_bytes,
            .bytes_rewritten = last_z.bytes_rewritten,
            .latencies = last_z.latencies,
        },
        .r = .{
            .allocator = allocator,
            .median_total_ns = r_totals[r_totals.len / 2],
            .median_build_ns = r_builds[r_builds.len / 2],
            .initial_serialized_bytes = last_r.initial_serialized_bytes,
            .bytes_rewritten = last_r.bytes_rewritten,
            .latencies = last_r.latencies,
        },
    };
}

fn percentile(values: *std.ArrayListUnmanaged(u64), numerator: usize, denominator: usize) u64 {
    if (values.items.len == 0) return 0;
    std.mem.sortUnstable(u64, values.items, {}, comptime std.sort.asc(u64));
    const index = @min(values.items.len - 1, (values.items.len * numerator + denominator - 1) / denominator - 1);
    return values.items[index];
}

fn printComparison(
    layout: model.Layout,
    workload: Workload,
    profile: Profile,
    trace: *const model.LoadedTrace,
    z: *Measurement,
    r: *Measurement,
) void {
    const txn_count: f64 = @floatFromInt(trace.txns.len);
    const z_ns_txn = @as(f64, @floatFromInt(z.median_total_ns)) / txn_count;
    const r_ns_txn = @as(f64, @floatFromInt(r.median_total_ns)) / txn_count;
    const winner = if (z_ns_txn < r_ns_txn) "zroar" else if (r_ns_txn < z_ns_txn) "CRoaring" else "tie";
    const ratio = if (z_ns_txn < r_ns_txn) r_ns_txn / z_ns_txn else if (r_ns_txn < z_ns_txn) z_ns_txn / r_ns_txn else 1.0;
    std.debug.print("\n{s}/{s}/{s}\n", .{ layout.name(), @tagName(workload), @tagName(profile) });
    if (workload == .read) {
        std.debug.print("  posting lists were materialized before the read timer started\n", .{});
    } else {
        std.debug.print("  posting-list inserts/removes/moves only; no SELECT operations\n", .{});
    }
    std.debug.print("  transactions {d}, operations {d}, operations/txn {d:.2}\n", .{
        trace.txns.len,
        trace.ops.len,
        @as(f64, @floatFromInt(trace.ops.len)) / txn_count,
    });
    std.debug.print("  {s:<12}{s:>14}{s:>16}{s:>14}{s:>16}{s:>16}\n", .{ "library", "ns/txn", "txn/s", "build ms", "stored bytes", "rewritten bytes" });
    std.debug.print("  {s:<12}{d:14.0}{d:16.0}{d:14.2}{d:16}{d:16}\n", .{
        "zroar", z_ns_txn, 1_000_000_000.0 / z_ns_txn, @as(f64, @floatFromInt(z.median_build_ns)) / 1e6, z.initial_serialized_bytes, z.bytes_rewritten,
    });
    std.debug.print("  {s:<12}{d:14.0}{d:16.0}{d:14.2}{d:16}{d:16}\n", .{
        "CRoaring", r_ns_txn, 1_000_000_000.0 / r_ns_txn, @as(f64, @floatFromInt(r.median_build_ns)) / 1e6, r.initial_serialized_bytes, r.bytes_rewritten,
    });
    if (std.mem.eql(u8, winner, "tie")) {
        std.debug.print("  result: tie\n", .{});
    } else {
        std.debug.print("  result: {s} {d:.2}x faster\n", .{ winner, ratio });
    }
    std.debug.print("  per-transaction latency from final sample (p50/p95 ns):\n", .{});
    for (std.enums.values(model.TransactionKind)) |kind| {
        const index = @intFromEnum(kind);
        if (z.latencies[index].items.len == 0 and r.latencies[index].items.len == 0) continue;
        std.debug.print("    {s:<14} zroar {d:>10}/{d:<10} CRoaring {d:>10}/{d:<10}\n", .{
            @tagName(kind),
            percentile(&z.latencies[index], 50, 100),
            percentile(&z.latencies[index], 95, 100),
            percentile(&r.latencies[index], 50, 100),
            percentile(&r.latencies[index], 95, 100),
        });
    }
}

fn usage() void {
    std.debug.print(
        \\usage: tpcc-bench <fixture-root> [options]
        \\
        \\  --layout dense|packed|scattered|all
        \\  --profile resident|serialized|all
        \\  --workload read|write|all     default read
        \\  --samples N        default 7; one additional warmup is always run
        \\
        \\This is a TPC-C-derived bitmap-index workload, not a TPC benchmark.
        \\Read timing contains no posting-list creation or mutation. Native posting
        \\lists are materialized beforehand and reported separately as build ms.
        \\The serialized profile excludes filesystem/page-cache I/O. Results are not tpmC.
        \\
    , .{});
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);
    var root: ?[]const u8 = null;
    var selected_layout: ?model.Layout = null;
    var selected_profile: ?Profile = null;
    var selected_workload: ?Workload = .read;
    var samples: usize = 7;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            usage();
            return;
        }
        if (std.mem.eql(u8, arg, "--layout") or std.mem.eql(u8, arg, "--profile") or
            std.mem.eql(u8, arg, "--workload") or std.mem.eql(u8, arg, "--samples"))
        {
            if (i + 1 >= args.len) return error.MissingOptionValue;
            i += 1;
            const value = args[i];
            if (std.mem.eql(u8, arg, "--layout")) {
                selected_layout = if (std.mem.eql(u8, value, "all")) null else std.meta.stringToEnum(model.Layout, value) orelse return error.BadLayout;
            } else if (std.mem.eql(u8, arg, "--profile")) {
                selected_profile = if (std.mem.eql(u8, value, "all")) null else std.meta.stringToEnum(Profile, value) orelse return error.BadProfile;
            } else if (std.mem.eql(u8, arg, "--workload")) {
                selected_workload = if (std.mem.eql(u8, value, "all")) null else std.meta.stringToEnum(Workload, value) orelse return error.BadWorkload;
            } else {
                samples = try std.fmt.parseInt(usize, value, 10);
                if (samples == 0) return error.InvalidSampleCount;
            }
        } else if (arg.len > 0 and arg[0] != '-' and root == null) {
            root = arg;
        } else {
            std.debug.print("unknown argument: {s}\n", .{arg});
            usage();
            return error.UnknownArgument;
        }
    }
    if (root == null) {
        usage();
        return error.MissingFixtureRoot;
    }
    std.debug.print("TPC-C 5.11-derived bitmap-index replay (not TPC-C; not tpmC)\n", .{});
    var summaries: std.ArrayListUnmanaged(Summary) = .empty;
    defer summaries.deinit(allocator);
    for (std.enums.values(model.Layout)) |layout| {
        if (selected_layout) |wanted| if (layout != wanted) continue;
        const layout_dir = try std.fs.path.join(allocator, &.{ root.?, layout.name() });
        defer allocator.free(layout_dir);
        var fixture = try model.loadFixture(io, allocator, layout_dir);
        defer fixture.deinit();
        var read_trace = try model.loadTrace(io, allocator, layout_dir, "read-trace.bin");
        defer read_trace.deinit();
        var write_trace = try model.loadTrace(io, allocator, layout_dir, "write-trace.bin");
        defer write_trace.deinit();
        try model.verifyManifest(io, allocator, layout_dir, &fixture, &read_trace, &write_trace);
        for (read_trace.ops) |op| if (model.isMutation(op.tag)) return error.MutationInReadTrace;
        for (write_trace.ops) |op| if (!model.isMutation(op.tag)) return error.ReadInWriteTrace;
        std.debug.print("\nloaded {s}: {d} posting lists, initial digest {x:0>16}; read {d} tx/{d} ops, write {d} tx/{d} ops\n", .{
            layout.name(),       fixture.postings.len, model.digestNeutral(fixture.postings),
            read_trace.txns.len, read_trace.ops.len,   write_trace.txns.len,
            write_trace.ops.len,
        });
        for (std.enums.values(Workload)) |workload| {
            if (selected_workload) |wanted| if (workload != wanted) continue;
            const trace = switch (workload) {
                .read => &read_trace,
                .write => &write_trace,
            };
            for (std.enums.values(Profile)) |profile| {
                if (selected_profile) |wanted| if (profile != wanted) continue;
                const z_first = (@intFromEnum(layout) + @intFromEnum(profile) + @intFromEnum(workload)) % 2 == 0;
                const pair = try measurePair(io, allocator, &fixture, trace, profile, samples, z_first);
                var z = pair.z;
                defer z.deinit();
                var r = pair.r;
                defer r.deinit();
                printComparison(layout, workload, profile, trace, &z, &r);
                const txn_count: f64 = @floatFromInt(trace.txns.len);
                try summaries.append(allocator, .{
                    .layout = layout,
                    .workload = workload,
                    .profile = profile,
                    .z_ns_per_txn = @as(f64, @floatFromInt(z.median_total_ns)) / txn_count,
                    .r_ns_per_txn = @as(f64, @floatFromInt(r.median_total_ns)) / txn_count,
                });
            }
        }
    }
    printSummary(summaries.items);
}

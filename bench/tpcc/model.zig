//! Deterministic, library-neutral TPC-C-derived secondary-index fixtures.

const std = @import("std");
const Bitmap = @import("zroar").Bitmap;

pub const postings_magic = "ZTPCCP01";
pub const trace_magic = "ZTPCCT01";
pub const format_version: u32 = 2;

pub const Layout = enum {
    dense,
    @"packed",
    scattered,

    pub fn name(self: Layout) []const u8 {
        return @tagName(self);
    }
};

pub const Table = enum(u8) { customer, order, order_line, stock, new_order };

pub const Index = enum(u16) {
    customer_warehouse,
    customer_district,
    customer_last,
    order_warehouse,
    order_district,
    order_customer,
    order_carrier,
    order_line_warehouse,
    order_line_district,
    order_line_order,
    order_line_item,
    order_line_delivered,
    stock_warehouse,
    stock_item,
    stock_quantity,
    new_order_warehouse,
    new_order_district,
};

pub const index_count = @typeInfo(Index).@"enum".fields.len;

pub const ListRef = struct {
    index: Index,
    value: u64,

    pub fn mapKey(self: ListRef) u128 {
        return (@as(u128, @intFromEnum(self.index)) << 64) | self.value;
    }
};

pub const OpTag = enum(u8) { probe, intersect, union_cardinality, insert, remove, move };

pub fn isMutation(tag: OpTag) bool {
    return tag == .insert or tag == .remove or tag == .move;
}

pub const Op = struct {
    tag: OpTag,
    a: ListRef,
    b: ListRef = .{ .index = .customer_warehouse, .value = 0 },
    key: u64 = 0,
    expected: u64 = 0,
};

pub const TransactionKind = enum(u8) { new_order, payment, order_status, delivery, stock_level };

pub const Txn = struct {
    kind: TransactionKind,
    first_op: u64,
    op_count: u32,
};

pub const Trace = struct {
    txns: std.ArrayListUnmanaged(Txn) = .empty,
    ops: std.ArrayListUnmanaged(Op) = .empty,

    pub fn deinit(self: *Trace, allocator: std.mem.Allocator) void {
        self.txns.deinit(allocator);
        self.ops.deinit(allocator);
        self.* = .{};
    }
};

pub const Scale = struct {
    warehouses: u32 = 10,
    districts_per_warehouse: u32 = 10,
    customers_per_district: u32 = 3_000,
    items: u32 = 100_000,
    decks_per_warehouse: u32 = 100,

    pub fn canonical(warehouses: u32, decks: u32) Scale {
        return .{ .warehouses = warehouses, .decks_per_warehouse = decks };
    }

    /// Fast, explicitly nonstandard scale for CI and local iteration.
    pub fn smoke(warehouses: u32, decks: u32) Scale {
        return .{
            .warehouses = warehouses,
            .districts_per_warehouse = 2,
            .customers_per_district = 100,
            .items = 1_000,
            .decks_per_warehouse = decks,
        };
    }

    pub fn newOrdersPerDistrict(self: Scale) u32 {
        return self.customers_per_district * 3 / 10;
    }

    pub fn transactionCount(self: Scale) u64 {
        return @as(u64, self.warehouses) * self.decks_per_warehouse * 23;
    }
};

pub const GenerateOptions = struct {
    out_dir: []const u8,
    scale: Scale = .{},
    seed: u64 = 0x5450_4343_5F35_3131,
    selected_layout: ?Layout = null,
};

const Posting = struct {
    ref: ListRef,
    keys: std.ArrayListUnmanaged(u64) = .empty,
    sorted: bool = true,
    bitmap: ?Bitmap = null,

    fn cardinality(self: *const Posting) u64 {
        return if (self.bitmap) |*bitmap| bitmap.getCardinality() else self.keys.items.len;
    }
};

pub const NeutralPosting = struct { ref: ListRef, keys: []u64 };

pub const Fixture = struct {
    allocator: std.mem.Allocator,
    postings: []NeutralPosting,
    sha256: [32]u8,

    pub fn deinit(self: *Fixture) void {
        for (self.postings) |p| self.allocator.free(p.keys);
        self.allocator.free(self.postings);
        self.* = undefined;
    }
};

pub const LoadedTrace = struct {
    allocator: std.mem.Allocator,
    txns: []Txn,
    ops: []Op,
    expected_final_digest: u64,
    sha256: [32]u8,

    pub fn deinit(self: *LoadedTrace) void {
        self.allocator.free(self.txns);
        self.allocator.free(self.ops);
        self.* = undefined;
    }
};

const State = struct {
    allocator: std.mem.Allocator,
    map: std.AutoHashMap(u128, usize),
    lists: std.ArrayListUnmanaged(Posting) = .empty,
    bitmaps_materialized: bool = false,

    fn init(allocator: std.mem.Allocator) State {
        return .{ .allocator = allocator, .map = std.AutoHashMap(u128, usize).init(allocator) };
    }

    fn deinit(self: *State) void {
        for (self.lists.items) |*posting| {
            posting.keys.deinit(self.allocator);
            if (posting.bitmap) |*bitmap| bitmap.deinit();
        }
        self.lists.deinit(self.allocator);
        self.map.deinit();
    }

    fn getOrCreate(self: *State, list_ref: ListRef) !*Posting {
        if (self.map.get(list_ref.mapKey())) |i| return &self.lists.items[i];
        var posting = Posting{ .ref = list_ref };
        if (self.bitmaps_materialized) posting.bitmap = try Bitmap.init(self.allocator);
        const i = self.lists.items.len;
        self.lists.append(self.allocator, posting) catch |err| {
            if (posting.bitmap) |*bitmap| bitmap.deinit();
            return err;
        };
        self.map.put(list_ref.mapKey(), i) catch |err| {
            var removed = self.lists.pop().?;
            if (removed.bitmap) |*bitmap| bitmap.deinit();
            return err;
        };
        return &self.lists.items[i];
    }

    fn get(self: *State, list_ref: ListRef) ?*Posting {
        const i = self.map.get(list_ref.mapKey()) orelse return null;
        return &self.lists.items[i];
    }

    fn addInitial(self: *State, list_ref: ListRef, key: u64) !void {
        if (self.bitmaps_materialized) return error.InitialPostingAfterBitmapMaterialization;
        const posting = try self.getOrCreate(list_ref);
        try posting.keys.append(self.allocator, key);
        posting.sorted = false;
    }

    fn sortPosting(posting: *Posting) void {
        if (posting.sorted) return;
        std.mem.sortUnstable(u64, posting.keys.items, {}, comptime std.sort.asc(u64));
        posting.sorted = true;
    }

    fn findVector(posting: *Posting, key: u64) bool {
        sortPosting(posting);
        var lo: usize = 0;
        var hi = posting.keys.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (posting.keys.items[mid] < key) lo = mid + 1 else hi = mid;
        }
        return lo < posting.keys.items.len and posting.keys.items[lo] == key;
    }

    fn contains(self: *State, list_ref: ListRef, key: u64) bool {
        const posting = self.get(list_ref) orelse return false;
        if (posting.bitmap) |*bitmap| return bitmap.contains(key);
        return findVector(posting, key);
    }

    fn insert(self: *State, list_ref: ListRef, key: u64) !bool {
        const posting = try self.getOrCreate(list_ref);
        if (posting.bitmap) |*bitmap| return bitmap.set(key);
        return error.BitmapStateNotMaterialized;
    }

    fn remove(self: *State, list_ref: ListRef, key: u64) bool {
        const posting = self.get(list_ref) orelse return false;
        if (posting.bitmap) |*bitmap| return bitmap.remove(key);
        return false;
    }

    fn intersectionCardinality(self: *State, a: ListRef, b: ListRef) u64 {
        const ap = self.get(a) orelse return 0;
        const bp = self.get(b) orelse return 0;
        if (ap.bitmap != null and bp.bitmap != null) return ap.bitmap.?.andCardinality(&bp.bitmap.?);
        sortPosting(ap);
        sortPosting(bp);
        var ai: usize = 0;
        var bi: usize = 0;
        var count: u64 = 0;
        while (ai < ap.keys.items.len and bi < bp.keys.items.len) {
            const av = ap.keys.items[ai];
            const bv = bp.keys.items[bi];
            if (av < bv) ai += 1 else if (bv < av) bi += 1 else {
                count += 1;
                ai += 1;
                bi += 1;
            }
        }
        return count;
    }

    fn unionCardinality(self: *State, a: ListRef, b: ListRef) u64 {
        const ap = self.get(a);
        const bp = self.get(b);
        if (ap == null) return if (bp) |p| p.cardinality() else 0;
        if (bp == null) return ap.?.cardinality();
        if (ap.?.bitmap != null and bp.?.bitmap != null) return ap.?.bitmap.?.orCardinality(&bp.?.bitmap.?);
        return ap.?.cardinality() + bp.?.cardinality() - self.intersectionCardinality(a, b);
    }

    fn execute(self: *State, op: Op) !u64 {
        return switch (op.tag) {
            .probe => @intFromBool(self.contains(op.a, op.key)),
            .intersect => self.intersectionCardinality(op.a, op.b),
            .union_cardinality => self.unionCardinality(op.a, op.b),
            .insert => @intFromBool(try self.insert(op.a, op.key)),
            .remove => @intFromBool(self.remove(op.a, op.key)),
            .move => blk: {
                const removed = self.remove(op.a, op.key);
                const added = try self.insert(op.b, op.key);
                break :blk @as(u64, @intFromBool(removed)) | (@as(u64, @intFromBool(added)) << 1);
            },
        };
    }

    fn sortLists(self: *State) !void {
        if (!self.bitmaps_materialized) for (self.lists.items) |*posting| sortPosting(posting);
        std.mem.sortUnstable(Posting, self.lists.items, {}, struct {
            fn less(_: void, a: Posting, b: Posting) bool {
                const ai = @intFromEnum(a.ref.index);
                const bi = @intFromEnum(b.ref.index);
                return ai < bi or (ai == bi and a.ref.value < b.ref.value);
            }
        }.less);
        self.map.clearRetainingCapacity();
        for (self.lists.items, 0..) |posting, i| try self.map.put(posting.ref.mapKey(), i);
    }

    fn materializeBitmaps(self: *State, progress: ?GenerationProgress) !void {
        if (self.bitmaps_materialized) return;
        try self.sortLists();
        errdefer for (self.lists.items) |*posting| {
            if (posting.bitmap) |*bitmap| bitmap.deinit();
            posting.bitmap = null;
        };
        var next_percent: usize = 10;
        for (self.lists.items, 0..) |*posting, posting_index| {
            var bitmap = try Bitmap.init(self.allocator);
            for (posting.keys.items) |key| {
                const changed = bitmap.set(key) catch |err| {
                    bitmap.deinit();
                    return err;
                };
                if (!changed) {
                    bitmap.deinit();
                    return error.DuplicateInitialPostingKey;
                }
            }
            posting.bitmap = bitmap;
            const completed = posting_index + 1;
            if (progress) |p| {
                if (completed == self.lists.items.len or completed * 100 >= self.lists.items.len * next_percent) {
                    p.report(completed, self.lists.items.len);
                    while (next_percent <= 100 and completed * 100 >= self.lists.items.len * next_percent) next_percent += 10;
                }
            }
        }
        for (self.lists.items) |*posting| {
            posting.keys.deinit(self.allocator);
            posting.keys = .empty;
        }
        self.bitmaps_materialized = true;
    }

    fn digest(self: *State) !u64 {
        try self.sortLists();
        var hash: u64 = fnv_offset;
        for (self.lists.items) |posting| {
            hashU64(&hash, @intFromEnum(posting.ref.index));
            hashU64(&hash, posting.ref.value);
            if (posting.bitmap) |*bitmap| {
                hashU64(&hash, bitmap.getCardinality());
                var it = bitmap.iterator();
                while (it.next()) |key| hashU64(&hash, key);
            } else {
                hashU64(&hash, posting.keys.items.len);
                for (posting.keys.items) |key| hashU64(&hash, key);
            }
        }
        return hash;
    }
};

pub const fnv_offset: u64 = 0xcbf2_9ce4_8422_2325;

pub fn hashU64(hash: *u64, value: u64) void {
    var v = value;
    for (0..8) |_| {
        hash.* = (hash.* ^ @as(u8, @truncate(v))) *% 0x0000_0100_0000_01b3;
        v >>= 8;
    }
}

pub fn digestNeutral(postings: []const NeutralPosting) u64 {
    var hash: u64 = fnv_offset;
    for (postings) |posting| {
        hashU64(&hash, @intFromEnum(posting.ref.index));
        hashU64(&hash, posting.ref.value);
        hashU64(&hash, posting.keys.len);
        for (posting.keys) |key| hashU64(&hash, key);
    }
    return hash;
}

fn list(index: Index, value: u64) ListRef {
    return .{ .index = index, .value = value };
}

fn wd(w: u32, d: u32) u64 {
    return (@as(u64, w) << 32) | d;
}

fn wdv(w: u32, d: u32, value: u32) u64 {
    return (@as(u64, w) << 48) | (@as(u64, d) << 32) | value;
}

fn splitMixBijection(input: u64) u64 {
    var z = input +% 0x9e37_79b9_7f4a_7c15;
    z = (z ^ (z >> 30)) *% 0xbf58_476d_1ce4_e5b9;
    z = (z ^ (z >> 27)) *% 0x94d0_49bb_1331_11eb;
    return z ^ (z >> 31);
}

fn tableSalt(table: Table) u64 {
    return switch (table) {
        .customer => 0x4355_5354_4f4d_4552,
        .order => 0x4f52_4445_525f_5f5f,
        .order_line => 0x4f52_4445_524c_494e,
        .stock => 0x5354_4f43_4b5f_5f5f,
        .new_order => 0x4e45_574f_5244_4552,
    };
}

const Keyer = struct {
    layout: Layout,
    scale: Scale,
    seed: u64,

    fn finish(self: Keyer, table: Table, dense: u64, packed_key: u64) u64 {
        return switch (self.layout) {
            .dense => dense,
            .@"packed" => packed_key,
            .scattered => splitMixBijection(dense ^ self.seed ^ tableSalt(table)),
        };
    }

    fn customer(self: Keyer, w: u32, d: u32, c: u32) u64 {
        const dense = ((@as(u64, w - 1) * self.scale.districts_per_warehouse + (d - 1)) * self.scale.customers_per_district) + c;
        return self.finish(.customer, dense, (@as(u64, w) << 16) | (@as(u64, d) << 12) | c);
    }

    fn order(self: Keyer, w: u32, d: u32, o: u32) u64 {
        const dense = ((@as(u64, w - 1) * self.scale.districts_per_warehouse + (d - 1)) * 0x0100_0000) + o;
        return self.finish(.order, dense, (@as(u64, w) << 28) | (@as(u64, d) << 24) | o);
    }

    fn orderLine(self: Keyer, dense_serial: u64, w: u32, d: u32, o: u32, line_no: u32) u64 {
        const packed_key = (@as(u64, w) << 32) | (@as(u64, d) << 28) | (@as(u64, o) << 4) | line_no;
        return self.finish(.order_line, dense_serial, packed_key);
    }

    fn stock(self: Keyer, w: u32, item: u32) u64 {
        const dense = @as(u64, w - 1) * self.scale.items + item;
        return self.finish(.stock, dense, (@as(u64, w) << 17) | item);
    }

    fn newOrder(self: Keyer, w: u32, d: u32, o: u32) u64 {
        const dense = ((@as(u64, w - 1) * self.scale.districts_per_warehouse + (d - 1)) * 0x0100_0000) + o;
        return self.finish(.new_order, dense, (@as(u64, w) << 28) | (@as(u64, d) << 24) | o);
    }
};

const Generator = struct {
    allocator: std.mem.Allocator,
    scale: Scale,
    keyer: Keyer,
    state: State,
    read_trace: Trace = .{},
    trace: Trace = .{},
    prng: std.Random.DefaultPrng,
    quantities: []u8,
    next_order: []u32,
    delivery_cursor: []u32,
    line_serial: u64 = 0,

    fn init(allocator: std.mem.Allocator, scale: Scale, layout: Layout, seed: u64) !Generator {
        if (scale.warehouses == 0 or scale.districts_per_warehouse == 0 or
            scale.customers_per_district == 0 or scale.items == 0 or
            scale.decks_per_warehouse == 0) return error.InvalidScale;
        if (scale.customers_per_district >= 4_096 or scale.items >= (1 << 17)) return error.PackedLayoutOverflow;
        const district_count = @as(usize, scale.warehouses) * scale.districts_per_warehouse;
        const quantities = try allocator.alloc(u8, @as(usize, scale.warehouses) * scale.items);
        errdefer allocator.free(quantities);
        const next_order = try allocator.alloc(u32, district_count);
        errdefer allocator.free(next_order);
        const delivery_cursor = try allocator.alloc(u32, district_count);
        return .{
            .allocator = allocator,
            .scale = scale,
            .keyer = .{ .layout = layout, .scale = scale, .seed = seed },
            .state = State.init(allocator),
            .prng = std.Random.DefaultPrng.init(seed),
            .quantities = quantities,
            .next_order = next_order,
            .delivery_cursor = delivery_cursor,
        };
    }

    fn deinit(self: *Generator) void {
        self.read_trace.deinit(self.allocator);
        self.trace.deinit(self.allocator);
        self.state.deinit();
        self.allocator.free(self.quantities);
        self.allocator.free(self.next_order);
        self.allocator.free(self.delivery_cursor);
    }

    fn districtSlot(self: Generator, w: u32, d: u32) usize {
        return @as(usize, w - 1) * self.scale.districts_per_warehouse + (d - 1);
    }

    fn quantitySlot(self: Generator, w: u32, item: u32) usize {
        return @as(usize, w - 1) * self.scale.items + (item - 1);
    }

    fn initial(self: *Generator, progress: ?GenerationProgress) !void {
        const rnd = self.prng.random();
        const cpd = self.scale.customers_per_district;
        const new_count = self.scale.newOrdersPerDistrict();
        for (1..self.scale.warehouses + 1) |w_value| {
            const w: u32 = @intCast(w_value);
            for (1..self.scale.items + 1) |item_value| {
                const item: u32 = @intCast(item_value);
                const quantity: u8 = @intCast(rnd.intRangeAtMost(u32, 10, 100));
                self.quantities[self.quantitySlot(w, item)] = quantity;
                const key = self.keyer.stock(w, item);
                try self.state.addInitial(list(.stock_warehouse, w), key);
                try self.state.addInitial(list(.stock_item, item), key);
                try self.state.addInitial(list(.stock_quantity, quantity), key);
            }
            for (1..self.scale.districts_per_warehouse + 1) |d_value| {
                const d: u32 = @intCast(d_value);
                const slot = self.districtSlot(w, d);
                self.next_order[slot] = cpd + 1;
                self.delivery_cursor[slot] = cpd - new_count + 1;

                for (1..cpd + 1) |c_value| {
                    const c: u32 = @intCast(c_value);
                    const key = self.keyer.customer(w, d, c);
                    const last = if (c <= 1_000) c - 1 else nurand(rnd, 255, 0, 999);
                    try self.state.addInitial(list(.customer_warehouse, w), key);
                    try self.state.addInitial(list(.customer_district, wd(w, d)), key);
                    try self.state.addInitial(list(.customer_last, wdv(w, d, last)), key);
                }

                const multiplier = coprimeMultiplier(cpd);
                const offset = (w * 97 + d * 31) % cpd;
                for (1..cpd + 1) |o_value| {
                    const o: u32 = @intCast(o_value);
                    const customer = ((o - 1) *% multiplier +% offset) % cpd + 1;
                    const order_key = self.keyer.order(w, d, o);
                    const undelivered = o > cpd - new_count;
                    const carrier: u32 = if (undelivered) 0 else rnd.intRangeAtMost(u32, 1, 10);
                    try self.state.addInitial(list(.order_warehouse, w), order_key);
                    try self.state.addInitial(list(.order_district, wd(w, d)), order_key);
                    try self.state.addInitial(list(.order_customer, wdv(w, d, customer)), order_key);
                    try self.state.addInitial(list(.order_carrier, wdv(w, d, carrier)), order_key);
                    if (undelivered) {
                        const no_key = self.keyer.newOrder(w, d, o);
                        try self.state.addInitial(list(.new_order_warehouse, w), no_key);
                        try self.state.addInitial(list(.new_order_district, wd(w, d)), no_key);
                    }

                    const line_count = rnd.intRangeAtMost(u32, 5, 15);
                    for (1..line_count + 1) |line_value| {
                        const line_no: u32 = @intCast(line_value);
                        self.line_serial += 1;
                        const line_key = self.keyer.orderLine(self.line_serial, w, d, o, line_no);
                        const item = nurand(rnd, 8_191, 1, self.scale.items);
                        try self.state.addInitial(list(.order_line_warehouse, w), line_key);
                        try self.state.addInitial(list(.order_line_district, wd(w, d)), line_key);
                        try self.state.addInitial(list(.order_line_order, wdv(w, d, o)), line_key);
                        try self.state.addInitial(list(.order_line_item, item), line_key);
                        try self.state.addInitial(list(.order_line_delivered, @intFromBool(!undelivered)), line_key);
                    }
                }
            }
            if (progress) |p| p.report(w, self.scale.warehouses);
        }
        try self.state.sortLists();
    }

    fn appendOp(self: *Generator, operation: Op) !void {
        if (!isMutation(operation.tag)) return;
        var completed = operation;
        completed.expected = try self.state.execute(completed);
        try self.trace.ops.append(self.allocator, completed);
    }

    fn finishTxn(self: *Generator, kind: TransactionKind, start: usize) !void {
        if (self.trace.ops.items.len == start) return;
        try self.trace.txns.append(self.allocator, .{
            .kind = kind,
            .first_op = start,
            .op_count = @intCast(self.trace.ops.items.len - start),
        });
    }

    fn generateTrace(self: *Generator, progress: ?GenerationProgress) !void {
        if (!self.state.bitmaps_materialized) try self.state.materializeBitmaps(null);
        var schedule: std.ArrayListUnmanaged(ScheduledTxn) = .empty;
        defer schedule.deinit(self.allocator);
        const rnd = self.prng.random();
        for (1..self.scale.warehouses + 1) |w_value| {
            const w: u32 = @intCast(w_value);
            for (0..self.scale.decks_per_warehouse) |_| {
                var deck = canonical_deck;
                rnd.shuffle(TransactionKind, &deck);
                for (deck) |kind| try schedule.append(self.allocator, .{ .kind = kind, .warehouse = w });
            }
        }
        rnd.shuffle(ScheduledTxn, schedule.items);
        var next_percent: usize = 10;
        for (schedule.items, 0..) |scheduled, txn_index| {
            try self.generateTxn(scheduled.kind, scheduled.warehouse);
            const completed = txn_index + 1;
            if (progress) |p| {
                if (completed == schedule.items.len or completed * 100 >= schedule.items.len * next_percent) {
                    p.report(completed, schedule.items.len);
                    while (next_percent <= 100 and completed * 100 >= schedule.items.len * next_percent) next_percent += 10;
                }
            }
        }
    }

    fn generateTxn(self: *Generator, kind: TransactionKind, w: u32) !void {
        const start = self.trace.ops.items.len;
        switch (kind) {
            .new_order => try self.newOrderTxn(w),
            .payment => try self.paymentTxn(w),
            .order_status => try self.orderStatusTxn(w),
            .delivery => try self.deliveryTxn(w),
            .stock_level => try self.stockLevelTxn(w),
        }
        try self.finishTxn(kind, start);
    }

    fn appendReadOp(self: *Generator, operation: Op) !void {
        if (isMutation(operation.tag)) return error.MutationInReadTrace;
        var completed = operation;
        completed.expected = try self.state.execute(completed);
        try self.read_trace.ops.append(self.allocator, completed);
    }

    fn finishReadTxn(self: *Generator, kind: TransactionKind, start: usize) !void {
        try self.read_trace.txns.append(self.allocator, .{
            .kind = kind,
            .first_op = start,
            .op_count = @intCast(self.read_trace.ops.items.len - start),
        });
    }

    /// Generate SELECT/index-lookup work against one immutable snapshot. No
    /// operation in this trace can create, remove, or rewrite a posting list.
    fn generateReadTrace(self: *Generator) !void {
        var schedule: std.ArrayListUnmanaged(ScheduledTxn) = .empty;
        defer schedule.deinit(self.allocator);
        var read_prng = std.Random.DefaultPrng.init(self.keyer.seed ^ 0x5245_4144_5f54_5243);
        const rnd = read_prng.random();
        for (1..self.scale.warehouses + 1) |w_value| {
            const w: u32 = @intCast(w_value);
            for (0..self.scale.decks_per_warehouse) |_| {
                var deck = canonical_deck;
                rnd.shuffle(TransactionKind, &deck);
                for (deck) |kind| try schedule.append(self.allocator, .{ .kind = kind, .warehouse = w });
            }
        }
        rnd.shuffle(ScheduledTxn, schedule.items);
        for (schedule.items) |scheduled| {
            const start = self.read_trace.ops.items.len;
            switch (scheduled.kind) {
                .new_order => try self.newOrderRead(scheduled.warehouse, rnd),
                .payment => try self.paymentRead(scheduled.warehouse, rnd),
                .order_status => try self.orderStatusRead(scheduled.warehouse, rnd),
                .delivery => try self.deliveryRead(scheduled.warehouse),
                .stock_level => try self.stockLevelRead(scheduled.warehouse, rnd),
            }
            try self.finishReadTxn(scheduled.kind, start);
        }
    }

    fn newOrderRead(self: *Generator, w: u32, rnd: std.Random) !void {
        const d = rnd.intRangeAtMost(u32, 1, self.scale.districts_per_warehouse);
        const c = nurand(rnd, 1_023, 1, self.scale.customers_per_district);
        try self.appendReadOp(.{
            .tag = .probe,
            .a = list(.customer_district, wd(w, d)),
            .key = self.keyer.customer(w, d, c),
        });
        const line_count = rnd.intRangeAtMost(u32, 5, 15);
        for (0..line_count) |_| {
            const item = nurand(rnd, 8_191, 1, self.scale.items);
            try self.appendReadOp(.{
                .tag = .probe,
                .a = list(.stock_item, item),
                .key = self.keyer.stock(w, item),
            });
        }
    }

    fn paymentRead(self: *Generator, w: u32, rnd: std.Random) !void {
        var customer_w = w;
        if (self.scale.warehouses > 1 and rnd.uintLessThan(u32, 100) < 15) {
            while (customer_w == w) customer_w = rnd.intRangeAtMost(u32, 1, self.scale.warehouses);
        }
        const d = rnd.intRangeAtMost(u32, 1, self.scale.districts_per_warehouse);
        if (rnd.uintLessThan(u32, 100) < 60) {
            const last = nurand(rnd, 255, 0, 999);
            try self.appendReadOp(.{
                .tag = .intersect,
                .a = list(.customer_district, wd(customer_w, d)),
                .b = list(.customer_last, wdv(customer_w, d, last)),
            });
        } else {
            const c = nurand(rnd, 1_023, 1, self.scale.customers_per_district);
            try self.appendReadOp(.{
                .tag = .probe,
                .a = list(.customer_district, wd(customer_w, d)),
                .key = self.keyer.customer(customer_w, d, c),
            });
        }
    }

    fn orderStatusRead(self: *Generator, w: u32, rnd: std.Random) !void {
        const d = rnd.intRangeAtMost(u32, 1, self.scale.districts_per_warehouse);
        var c = nurand(rnd, 1_023, 1, self.scale.customers_per_district);
        if (rnd.uintLessThan(u32, 100) < 60) {
            const last = nurand(rnd, 255, 0, 999);
            try self.appendReadOp(.{
                .tag = .intersect,
                .a = list(.customer_district, wd(w, d)),
                .b = list(.customer_last, wdv(w, d, last)),
            });
            c = (last % self.scale.customers_per_district) + 1;
        }
        try self.appendReadOp(.{
            .tag = .intersect,
            .a = list(.order_district, wd(w, d)),
            .b = list(.order_customer, wdv(w, d, c)),
        });
    }

    fn deliveryRead(self: *Generator, w: u32) !void {
        for (1..self.scale.districts_per_warehouse + 1) |d_value| {
            const d: u32 = @intCast(d_value);
            const queue = list(.new_order_district, wd(w, d));
            try self.appendReadOp(.{ .tag = .intersect, .a = queue, .b = queue });
        }
    }

    fn stockLevelRead(self: *Generator, w: u32, rnd: std.Random) !void {
        const threshold = rnd.intRangeAtMost(u32, 10, 20);
        for (10..threshold) |quantity| {
            try self.appendReadOp(.{
                .tag = .intersect,
                .a = list(.stock_warehouse, w),
                .b = list(.stock_quantity, quantity),
            });
            if ((quantity - 10) % 2 == 0 and quantity + 1 < threshold) {
                try self.appendReadOp(.{
                    .tag = .union_cardinality,
                    .a = list(.stock_quantity, quantity),
                    .b = list(.stock_quantity, quantity + 1),
                });
            }
        }
        for (0..20) |_| {
            const item = nurand(rnd, 8_191, 1, self.scale.items);
            try self.appendReadOp(.{
                .tag = .probe,
                .a = list(.stock_item, item),
                .key = self.keyer.stock(w, item),
            });
        }
    }

    fn newOrderTxn(self: *Generator, w: u32) !void {
        const rnd = self.prng.random();
        const d = rnd.intRangeAtMost(u32, 1, self.scale.districts_per_warehouse);
        const c = nurand(rnd, 1_023, 1, self.scale.customers_per_district);
        try self.appendOp(.{
            .tag = .probe,
            .a = list(.customer_district, wd(w, d)),
            .key = self.keyer.customer(w, d, c),
        });

        const line_count = rnd.intRangeAtMost(u32, 5, 15);
        const rollback = rnd.uintLessThan(u32, 100) == 0;
        var items: [15]u32 = undefined;
        for (0..line_count) |i| {
            items[i] = if (rollback and i + 1 == line_count)
                self.scale.items + 1
            else
                nurand(rnd, 8_191, 1, self.scale.items);
            const stock_key = if (items[i] <= self.scale.items) self.keyer.stock(w, items[i]) else 0;
            try self.appendOp(.{ .tag = .probe, .a = list(.stock_item, items[i]), .key = stock_key });
        }
        if (rollback) return;

        const slot = self.districtSlot(w, d);
        const o = self.next_order[slot];
        self.next_order[slot] += 1;
        const order_key = self.keyer.order(w, d, o);
        try self.appendOp(.{ .tag = .insert, .a = list(.order_warehouse, w), .key = order_key });
        try self.appendOp(.{ .tag = .insert, .a = list(.order_district, wd(w, d)), .key = order_key });
        try self.appendOp(.{ .tag = .insert, .a = list(.order_customer, wdv(w, d, c)), .key = order_key });
        try self.appendOp(.{ .tag = .insert, .a = list(.order_carrier, wdv(w, d, 0)), .key = order_key });
        const no_key = self.keyer.newOrder(w, d, o);
        try self.appendOp(.{ .tag = .insert, .a = list(.new_order_warehouse, w), .key = no_key });
        try self.appendOp(.{ .tag = .insert, .a = list(.new_order_district, wd(w, d)), .key = no_key });

        for (items[0..line_count], 1..) |item, line_value| {
            const line_no: u32 = @intCast(line_value);
            self.line_serial += 1;
            const line_key = self.keyer.orderLine(self.line_serial, w, d, o, line_no);
            try self.appendOp(.{ .tag = .insert, .a = list(.order_line_warehouse, w), .key = line_key });
            try self.appendOp(.{ .tag = .insert, .a = list(.order_line_district, wd(w, d)), .key = line_key });
            try self.appendOp(.{ .tag = .insert, .a = list(.order_line_order, wdv(w, d, o)), .key = line_key });
            try self.appendOp(.{ .tag = .insert, .a = list(.order_line_item, item), .key = line_key });
            try self.appendOp(.{ .tag = .insert, .a = list(.order_line_delivered, 0), .key = line_key });

            const qslot = self.quantitySlot(w, item);
            const old_q = self.quantities[qslot];
            const ordered = rnd.intRangeAtMost(u8, 1, 10);
            const new_q: u8 = if (old_q >= ordered + 10) old_q - ordered else old_q + 91 - ordered;
            try self.appendOp(.{
                .tag = .move,
                .a = list(.stock_quantity, old_q),
                .b = list(.stock_quantity, new_q),
                .key = self.keyer.stock(w, item),
            });
            self.quantities[qslot] = new_q;
        }
    }

    fn paymentTxn(self: *Generator, w: u32) !void {
        const rnd = self.prng.random();
        var customer_w = w;
        if (self.scale.warehouses > 1 and rnd.uintLessThan(u32, 100) < 15) {
            while (customer_w == w) customer_w = rnd.intRangeAtMost(u32, 1, self.scale.warehouses);
        }
        const d = rnd.intRangeAtMost(u32, 1, self.scale.districts_per_warehouse);
        if (rnd.uintLessThan(u32, 100) < 60) {
            const last = nurand(rnd, 255, 0, 999);
            try self.appendOp(.{
                .tag = .intersect,
                .a = list(.customer_district, wd(customer_w, d)),
                .b = list(.customer_last, wdv(customer_w, d, last)),
            });
        } else {
            const c = nurand(rnd, 1_023, 1, self.scale.customers_per_district);
            try self.appendOp(.{
                .tag = .probe,
                .a = list(.customer_district, wd(customer_w, d)),
                .key = self.keyer.customer(customer_w, d, c),
            });
        }
    }

    fn orderStatusTxn(self: *Generator, w: u32) !void {
        const rnd = self.prng.random();
        const d = rnd.intRangeAtMost(u32, 1, self.scale.districts_per_warehouse);
        var c = nurand(rnd, 1_023, 1, self.scale.customers_per_district);
        if (rnd.uintLessThan(u32, 100) < 60) {
            const last = nurand(rnd, 255, 0, 999);
            try self.appendOp(.{
                .tag = .intersect,
                .a = list(.customer_district, wd(w, d)),
                .b = list(.customer_last, wdv(w, d, last)),
            });
            c = (last % self.scale.customers_per_district) + 1;
        }
        try self.appendOp(.{
            .tag = .intersect,
            .a = list(.order_district, wd(w, d)),
            .b = list(.order_customer, wdv(w, d, c)),
        });
    }

    fn deliveryTxn(self: *Generator, w: u32) !void {
        const rnd = self.prng.random();
        const carrier = rnd.intRangeAtMost(u32, 1, 10);
        for (1..self.scale.districts_per_warehouse + 1) |d_value| {
            const d: u32 = @intCast(d_value);
            const slot = self.districtSlot(w, d);
            const o = self.delivery_cursor[slot];
            if (o >= self.next_order[slot]) continue;
            self.delivery_cursor[slot] += 1;
            const no_key = self.keyer.newOrder(w, d, o);
            try self.appendOp(.{ .tag = .remove, .a = list(.new_order_warehouse, w), .key = no_key });
            try self.appendOp(.{ .tag = .remove, .a = list(.new_order_district, wd(w, d)), .key = no_key });
            try self.appendOp(.{
                .tag = .move,
                .a = list(.order_carrier, wdv(w, d, 0)),
                .b = list(.order_carrier, wdv(w, d, carrier)),
                .key = self.keyer.order(w, d, o),
            });
            const line_ref = list(.order_line_order, wdv(w, d, o));
            const posting = self.state.get(line_ref) orelse continue;
            const bitmap = if (posting.bitmap) |*value| value else return error.BitmapStateNotMaterialized;
            const line_keys = try bitmap.toArray(self.allocator);
            defer self.allocator.free(line_keys);
            for (line_keys) |line_key| {
                try self.appendOp(.{
                    .tag = .move,
                    .a = list(.order_line_delivered, 0),
                    .b = list(.order_line_delivered, 1),
                    .key = line_key,
                });
            }
        }
    }

    fn stockLevelTxn(self: *Generator, w: u32) !void {
        const rnd = self.prng.random();
        const threshold = rnd.intRangeAtMost(u32, 10, 20);
        for (10..threshold) |quantity| {
            try self.appendOp(.{
                .tag = .intersect,
                .a = list(.stock_warehouse, w),
                .b = list(.stock_quantity, quantity),
            });
            if ((quantity - 10) % 2 == 0 and quantity + 1 < threshold) {
                try self.appendOp(.{
                    .tag = .union_cardinality,
                    .a = list(.stock_quantity, quantity),
                    .b = list(.stock_quantity, quantity + 1),
                });
            }
        }
        // The SQL join supplies recent item ids. Probe a deterministic sample;
        // row materialization and join execution are deliberately out of scope.
        for (0..20) |_| {
            const item = nurand(rnd, 8_191, 1, self.scale.items);
            try self.appendOp(.{
                .tag = .probe,
                .a = list(.stock_item, item),
                .key = self.keyer.stock(w, item),
            });
        }
    }
};

const ScheduledTxn = struct { kind: TransactionKind, warehouse: u32 };

const GenerationProgress = struct {
    io: std.Io,
    layout: Layout,
    layout_number: usize,
    layout_count: usize,
    phase: []const u8,
    started: std.Io.Clock.Timestamp,

    fn report(self: GenerationProgress, completed: usize, total: usize) void {
        const elapsed_ms: u64 = @intCast(self.started.untilNow(self.io).raw.toMilliseconds());
        const remaining_ms = if (completed == 0)
            0
        else
            elapsed_ms * (total - completed) / completed;
        const percent = if (total == 0) 100 else completed * 100 / total;
        std.debug.print(
            "[{d}/{d} {s}] {s}: {d}/{d} ({d}%), elapsed {d}.{d:0>3}s, ETA {d}.{d:0>3}s\n",
            .{
                self.layout_number,
                self.layout_count,
                self.layout.name(),
                self.phase,
                completed,
                total,
                percent,
                elapsed_ms / 1_000,
                elapsed_ms % 1_000,
                remaining_ms / 1_000,
                remaining_ms % 1_000,
            },
        );
    }
};

pub const canonical_deck = [_]TransactionKind{
    .new_order,    .new_order, .new_order,   .new_order, .new_order,
    .new_order,    .new_order, .new_order,   .new_order, .new_order,
    .payment,      .payment,   .payment,     .payment,   .payment,
    .payment,      .payment,   .payment,     .payment,   .payment,
    .order_status, .delivery,  .stock_level,
};

fn nurand(rnd: std.Random, a: u32, x: u32, y: u32) u32 {
    if (x == y) return x;
    const c: u32 = 42;
    return (((rnd.intRangeAtMost(u32, 0, a) | rnd.intRangeAtMost(u32, x, y)) + c) % (y - x + 1)) + x;
}

fn coprimeMultiplier(modulus: u32) u32 {
    var candidate: u32 = 17;
    while (std.math.gcd(candidate, modulus) != 1) candidate += 2;
    return candidate;
}

const Sink = struct {
    writer: *std.Io.Writer,
    sha: std.crypto.hash.sha2.Sha256 = .init(.{}),

    fn bytes(self: *Sink, value: []const u8) !void {
        try self.writer.writeAll(value);
        self.sha.update(value);
    }

    fn int(self: *Sink, comptime T: type, value: T) !void {
        var buf: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &buf, value, .little);
        try self.bytes(&buf);
    }

    fn finish(self: *Sink) [32]u8 {
        var digest: [32]u8 = undefined;
        self.sha.final(&digest);
        return digest;
    }
};

fn writePostings(io: std.Io, path: []const u8, state: *State) ![32]u8 {
    try state.sortLists();
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var file_writer = file.writer(io, &buffer);
    var sink = Sink{ .writer = &file_writer.interface };
    try sink.bytes(postings_magic);
    try sink.int(u32, format_version);
    try sink.int(u32, index_count);
    try sink.int(u64, state.lists.items.len);
    for (state.lists.items) |posting| {
        try sink.int(u16, @intFromEnum(posting.ref.index));
        try sink.int(u16, 0);
        try sink.int(u32, 0);
        try sink.int(u64, posting.ref.value);
        if (posting.bitmap != null) return error.SnapshotWrittenAfterBitmapMutation;
        try sink.int(u64, posting.keys.items.len);
        for (posting.keys.items) |key| try sink.int(u64, key);
    }
    try file_writer.flush();
    return sink.finish();
}

fn writeTrace(io: std.Io, path: []const u8, trace: *const Trace, final_digest: u64) ![32]u8 {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
    defer file.close(io);
    var buffer: [64 * 1024]u8 = undefined;
    var file_writer = file.writer(io, &buffer);
    var sink = Sink{ .writer = &file_writer.interface };
    try sink.bytes(trace_magic);
    try sink.int(u32, format_version);
    try sink.int(u32, 0);
    try sink.int(u64, trace.txns.items.len);
    try sink.int(u64, trace.ops.items.len);
    try sink.int(u64, final_digest);
    for (trace.txns.items) |txn| {
        try sink.int(u8, @intFromEnum(txn.kind));
        try sink.int(u8, 0);
        try sink.int(u16, 0);
        try sink.int(u32, txn.op_count);
        try sink.int(u64, txn.first_op);
    }
    for (trace.ops.items) |op| {
        try sink.int(u8, @intFromEnum(op.tag));
        try sink.int(u8, 0);
        try sink.int(u16, @intFromEnum(op.a.index));
        try sink.int(u16, @intFromEnum(op.b.index));
        try sink.int(u16, 0);
        try sink.int(u64, op.a.value);
        try sink.int(u64, op.b.value);
        try sink.int(u64, op.key);
        try sink.int(u64, op.expected);
    }
    try file_writer.flush();
    return sink.finish();
}

fn writeManifest(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    layout: Layout,
    scale: Scale,
    seed: u64,
    posting_list_count: usize,
    read_trace: *const Trace,
    write_trace: *const Trace,
    initial_digest: u64,
    final_digest: u64,
    postings_sha: [32]u8,
    read_trace_sha: [32]u8,
    write_trace_sha: [32]u8,
) !void {
    const postings_hex = std.fmt.bytesToHex(postings_sha, .lower);
    const read_trace_hex = std.fmt.bytesToHex(read_trace_sha, .lower);
    const write_trace_hex = std.fmt.bytesToHex(write_trace_sha, .lower);
    const canonical = scale.districts_per_warehouse == 10 and scale.customers_per_district == 3_000 and scale.items == 100_000;
    const json = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "format": "zroar-tpcc-index-v2",
        \\  "derived_from": "TPC-C 5.11",
        \\  "comparable_to_tpc_results": false,
        \\  "disclaimer": "Not a TPC benchmark; no tpmC claim. Bitmap-index operations only.",
        \\  "layout": "{s}",
        \\  "canonical_population": {s},
        \\  "seed": {d},
        \\  "warehouses": {d},
        \\  "districts_per_warehouse": {d},
        \\  "customers_per_district": {d},
        \\  "items": {d},
        \\  "decks_per_warehouse": {d},
        \\  "read_transactions": {d},
        \\  "read_operations": {d},
        \\  "write_transactions": {d},
        \\  "write_operations": {d},
        \\  "posting_lists": {d},
        \\  "initial_digest": "{x:0>16}",
        \\  "final_digest": "{x:0>16}",
        \\  "postings_sha256": "{s}",
        \\  "read_trace_sha256": "{s}",
        \\  "write_trace_sha256": "{s}",
        \\  "files": ["postings.bin", "read-trace.bin", "write-trace.bin"],
        \\  "indices": ["customer_warehouse", "customer_district", "customer_last", "order_warehouse", "order_district", "order_customer", "order_carrier", "order_line_warehouse", "order_line_district", "order_line_order", "order_line_item", "order_line_delivered", "stock_warehouse", "stock_item", "stock_quantity", "new_order_warehouse", "new_order_district"]
        \\}}
        \\
    , .{
        layout.name(),
        if (canonical) "true" else "false",
        seed,
        scale.warehouses,
        scale.districts_per_warehouse,
        scale.customers_per_district,
        scale.items,
        scale.decks_per_warehouse,
        read_trace.txns.items.len,
        read_trace.ops.items.len,
        write_trace.txns.items.len,
        write_trace.ops.items.len,
        posting_list_count,
        initial_digest,
        final_digest,
        &postings_hex,
        &read_trace_hex,
        &write_trace_hex,
    });
    defer allocator.free(json);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = json, .flags = .{ .exclusive = true } });
}

fn generateLayout(
    io: std.Io,
    allocator: std.mem.Allocator,
    root: []const u8,
    layout: Layout,
    scale: Scale,
    seed: u64,
    layout_number: usize,
    layout_count: usize,
) !void {
    const layout_started = std.Io.Clock.Timestamp.now(io, .awake);
    std.debug.print("[{d}/{d} {s}] building neutral initial posting lists\n", .{ layout_number, layout_count, layout.name() });
    const layout_dir = try std.fs.path.join(allocator, &.{ root, layout.name() });
    defer allocator.free(layout_dir);
    try std.Io.Dir.cwd().createDirPath(io, layout_dir);
    var generator = try Generator.init(allocator, scale, layout, seed);
    defer generator.deinit();
    const population_started = std.Io.Clock.Timestamp.now(io, .awake);
    try generator.initial(.{
        .io = io,
        .layout = layout,
        .layout_number = layout_number,
        .layout_count = layout_count,
        .phase = "population",
        .started = population_started,
    });
    const initial_digest = try generator.state.digest();
    const initial_list_count = generator.state.lists.items.len;

    std.debug.print("[{d}/{d} {s}] writing neutral postings.bin ({d} posting lists)\n", .{
        layout_number,
        layout_count,
        layout.name(),
        initial_list_count,
    });
    const postings_path = try std.fs.path.join(allocator, &.{ layout_dir, "postings.bin" });
    defer allocator.free(postings_path);
    const postings_sha = try writePostings(io, postings_path, &generator.state);
    const read_started = std.Io.Clock.Timestamp.now(io, .awake);
    std.debug.print("[{d}/{d} {s}] generating immutable read trace\n", .{ layout_number, layout_count, layout.name() });
    try generator.generateReadTrace();
    const read_trace_path = try std.fs.path.join(allocator, &.{ layout_dir, "read-trace.bin" });
    defer allocator.free(read_trace_path);
    const read_trace_sha = try writeTrace(io, read_trace_path, &generator.read_trace, initial_digest);
    const read_ms: u64 = @intCast(read_started.untilNow(io).raw.toMilliseconds());
    std.debug.print("[{d}/{d} {s}] read trace complete: {d} transactions, {d} operations in {d}.{d:0>3}s\n", .{
        layout_number,
        layout_count,
        layout.name(),
        generator.read_trace.txns.items.len,
        generator.read_trace.ops.items.len,
        read_ms / 1_000,
        read_ms % 1_000,
    });

    const bitmap_started = std.Io.Clock.Timestamp.now(io, .awake);
    std.debug.print("[{d}/{d} {s}] materializing sorted postings as resident zroar bitmaps\n", .{
        layout_number,
        layout_count,
        layout.name(),
    });
    try generator.state.materializeBitmaps(.{
        .io = io,
        .layout = layout,
        .layout_number = layout_number,
        .layout_count = layout_count,
        .phase = "zroar materialization",
        .started = bitmap_started,
    });

    const write_started = std.Io.Clock.Timestamp.now(io, .awake);
    std.debug.print("[{d}/{d} {s}] generating mutable write trace\n", .{ layout_number, layout_count, layout.name() });
    try generator.generateTrace(.{
        .io = io,
        .layout = layout,
        .layout_number = layout_number,
        .layout_count = layout_count,
        .phase = "write trace",
        .started = write_started,
    });
    const final_digest = try generator.state.digest();
    const write_trace_path = try std.fs.path.join(allocator, &.{ layout_dir, "write-trace.bin" });
    defer allocator.free(write_trace_path);
    const write_trace_sha = try writeTrace(io, write_trace_path, &generator.trace, final_digest);
    const manifest_path = try std.fs.path.join(allocator, &.{ layout_dir, "manifest.json" });
    defer allocator.free(manifest_path);
    try writeManifest(
        io,
        allocator,
        manifest_path,
        layout,
        scale,
        seed,
        initial_list_count,
        &generator.read_trace,
        &generator.trace,
        initial_digest,
        final_digest,
        postings_sha,
        read_trace_sha,
        write_trace_sha,
    );
    const layout_ms: u64 = @intCast(layout_started.untilNow(io).raw.toMilliseconds());
    std.debug.print("[{d}/{d} {s}] complete in {d}.{d:0>3}s\n", .{
        layout_number,
        layout_count,
        layout.name(),
        layout_ms / 1_000,
        layout_ms % 1_000,
    });
}

/// Refuses an existing output, generates into a unique sibling, then publishes by
/// rename. A unique staging name allows a retry after an interrupted generation;
/// abandoned staging directories can be removed independently.
pub fn generate(io: std.Io, allocator: std.mem.Allocator, options: GenerateOptions) !void {
    const cwd = std.Io.Dir.cwd();
    const output_exists = blk: {
        cwd.access(io, options.out_dir, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => return err,
        };
        break :blk true;
    };
    if (output_exists) return error.OutputAlreadyExists;

    var random_suffix: u64 = undefined;
    var tmp: []const u8 = undefined;
    for (0..8) |_| {
        io.random(std.mem.asBytes(&random_suffix));
        tmp = try std.fmt.allocPrint(allocator, "{s}.tmp-{x:0>16}", .{ options.out_dir, random_suffix });
        const status = try cwd.createDirPathStatus(io, tmp, .default_dir);
        if (status == .created) break;
        allocator.free(tmp);
    } else return error.UnableToCreateTemporaryOutput;
    defer allocator.free(tmp);
    errdefer cwd.deleteTree(io, tmp) catch {};
    if (options.selected_layout) |layout| {
        try generateLayout(io, allocator, tmp, layout, options.scale, options.seed, 1, 1);
    } else {
        const layouts = std.enums.values(Layout);
        for (layouts, 0..) |layout, layout_index| {
            try generateLayout(io, allocator, tmp, layout, options.scale, options.seed, layout_index + 1, layouts.len);
        }
    }
    try std.Io.Dir.renamePreserve(cwd, tmp, cwd, options.out_dir, io);
}

const Cursor = struct {
    bytes: []const u8,
    offset: usize = 0,

    fn take(self: *Cursor, n: usize) ![]const u8 {
        if (n > self.bytes.len -| self.offset) return error.TruncatedFixture;
        const result = self.bytes[self.offset..][0..n];
        self.offset += n;
        return result;
    }

    fn int(self: *Cursor, comptime T: type) !T {
        return std.mem.readInt(T, (try self.take(@sizeOf(T)))[0..@sizeOf(T)], .little);
    }
};

pub fn loadFixture(io: std.Io, allocator: std.mem.Allocator, layout_dir: []const u8) !Fixture {
    const path = try std.fs.path.join(allocator, &.{ layout_dir, "postings.bin" });
    defer allocator.free(path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(8 * 1024 * 1024 * 1024));
    defer allocator.free(bytes);
    var sha256: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &sha256, .{});
    var cursor = Cursor{ .bytes = bytes };
    if (!std.mem.eql(u8, try cursor.take(8), postings_magic)) return error.BadPostingsMagic;
    if (try cursor.int(u32) != format_version) return error.UnsupportedFixtureVersion;
    if (try cursor.int(u32) != index_count) return error.BadIndexCatalog;
    const postings = try allocator.alloc(NeutralPosting, @intCast(try cursor.int(u64)));
    errdefer allocator.free(postings);
    var initialized: usize = 0;
    errdefer for (postings[0..initialized]) |posting| allocator.free(posting.keys);
    for (postings) |*posting| {
        const index = std.enums.fromInt(Index, try cursor.int(u16)) orelse return error.BadIndexId;
        _ = try cursor.int(u16);
        _ = try cursor.int(u32);
        const value = try cursor.int(u64);
        const keys = try allocator.alloc(u64, @intCast(try cursor.int(u64)));
        for (keys) |*key| key.* = try cursor.int(u64);
        posting.* = .{ .ref = .{ .index = index, .value = value }, .keys = keys };
        initialized += 1;
    }
    if (cursor.offset != bytes.len) return error.TrailingFixtureData;
    return .{ .allocator = allocator, .postings = postings, .sha256 = sha256 };
}

pub fn loadTrace(io: std.Io, allocator: std.mem.Allocator, layout_dir: []const u8, file_name: []const u8) !LoadedTrace {
    const path = try std.fs.path.join(allocator, &.{ layout_dir, file_name });
    defer allocator.free(path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(8 * 1024 * 1024 * 1024));
    defer allocator.free(bytes);
    var sha256: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &sha256, .{});
    var cursor = Cursor{ .bytes = bytes };
    if (!std.mem.eql(u8, try cursor.take(8), trace_magic)) return error.BadTraceMagic;
    if (try cursor.int(u32) != format_version) return error.UnsupportedFixtureVersion;
    _ = try cursor.int(u32);
    const txn_count = try cursor.int(u64);
    const op_count = try cursor.int(u64);
    const expected_final_digest = try cursor.int(u64);
    const txns = try allocator.alloc(Txn, @intCast(txn_count));
    errdefer allocator.free(txns);
    for (txns) |*txn| {
        const kind = std.enums.fromInt(TransactionKind, try cursor.int(u8)) orelse return error.BadTransactionKind;
        _ = try cursor.int(u8);
        _ = try cursor.int(u16);
        const count = try cursor.int(u32);
        const first = try cursor.int(u64);
        if (first > op_count or count > op_count - first) return error.BadTransactionRange;
        txn.* = .{ .kind = kind, .first_op = first, .op_count = count };
    }
    const ops = try allocator.alloc(Op, @intCast(op_count));
    errdefer allocator.free(ops);
    for (ops) |*op| {
        const tag = std.enums.fromInt(OpTag, try cursor.int(u8)) orelse return error.BadOperationTag;
        _ = try cursor.int(u8);
        const ai = std.enums.fromInt(Index, try cursor.int(u16)) orelse return error.BadIndexId;
        const bi = std.enums.fromInt(Index, try cursor.int(u16)) orelse return error.BadIndexId;
        _ = try cursor.int(u16);
        const av = try cursor.int(u64);
        const bv = try cursor.int(u64);
        const key = try cursor.int(u64);
        const expected = try cursor.int(u64);
        op.* = .{ .tag = tag, .a = .{ .index = ai, .value = av }, .b = .{ .index = bi, .value = bv }, .key = key, .expected = expected };
    }
    if (cursor.offset != bytes.len) return error.TrailingFixtureData;
    return .{ .allocator = allocator, .txns = txns, .ops = ops, .expected_final_digest = expected_final_digest, .sha256 = sha256 };
}

pub fn verifyManifest(
    io: std.Io,
    allocator: std.mem.Allocator,
    layout_dir: []const u8,
    fixture: *const Fixture,
    read_trace: *const LoadedTrace,
    write_trace: *const LoadedTrace,
) !void {
    const path = try std.fs.path.join(allocator, &.{ layout_dir, "manifest.json" });
    defer allocator.free(path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 20));
    defer allocator.free(bytes);
    const ManifestChecksums = struct {
        postings_sha256: []const u8,
        read_trace_sha256: []const u8,
        write_trace_sha256: []const u8,
    };
    var parsed = try std.json.parseFromSlice(ManifestChecksums, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const postings_hex = std.fmt.bytesToHex(fixture.sha256, .lower);
    const read_trace_hex = std.fmt.bytesToHex(read_trace.sha256, .lower);
    const write_trace_hex = std.fmt.bytesToHex(write_trace.sha256, .lower);
    if (!std.mem.eql(u8, parsed.value.postings_sha256, &postings_hex) or
        !std.mem.eql(u8, parsed.value.read_trace_sha256, &read_trace_hex) or
        !std.mem.eql(u8, parsed.value.write_trace_sha256, &write_trace_hex)) return error.ChecksumMismatch;
}

test "canonical scale and transaction deck match TPC-C 5.11 proportions" {
    const scale = Scale{};
    try std.testing.expectEqual(@as(u32, 900), scale.newOrdersPerDistrict());
    try std.testing.expectEqual(@as(u64, 23_000), scale.transactionCount());
    var counts = [_]u32{0} ** 5;
    for (canonical_deck) |kind| counts[@intFromEnum(kind)] += 1;
    try std.testing.expectEqualSlices(u32, &.{ 10, 10, 1, 1, 1 }, &counts);
}

test "all key layouts preserve primary-key uniqueness" {
    const scale = Scale.smoke(2, 1);
    for (std.enums.values(Layout)) |layout| {
        const keyer = Keyer{ .layout = layout, .scale = scale, .seed = 1234 };
        var seen = std.AutoHashMap(u64, void).init(std.testing.allocator);
        defer seen.deinit();
        for (1..scale.warehouses + 1) |w| for (1..scale.districts_per_warehouse + 1) |d| for (1..scale.customers_per_district + 1) |c| {
            const result = try seen.getOrPut(keyer.customer(@intCast(w), @intCast(d), @intCast(c)));
            try std.testing.expect(!result.found_existing);
        };
    }
}

test "reference trace and final digest are deterministic" {
    var first = try Generator.init(std.testing.allocator, Scale.smoke(1, 1), .dense, 99);
    defer first.deinit();
    try first.initial(null);
    try first.generateReadTrace();
    try first.generateTrace(null);
    const first_digest = try first.state.digest();

    var second = try Generator.init(std.testing.allocator, Scale.smoke(1, 1), .dense, 99);
    defer second.deinit();
    try second.initial(null);
    try second.generateReadTrace();
    try second.generateTrace(null);
    try std.testing.expectEqual(first_digest, try second.state.digest());
    try std.testing.expectEqual(first.trace.txns.items.len, second.trace.txns.items.len);
    try std.testing.expectEqual(first.trace.ops.items.len, second.trace.ops.items.len);
    try std.testing.expectEqual(first.read_trace.txns.items.len, second.read_trace.txns.items.len);
    try std.testing.expectEqual(first.read_trace.ops.items.len, second.read_trace.ops.items.len);
    for (first.read_trace.ops.items) |op| try std.testing.expect(!isMutation(op.tag));
    for (first.trace.ops.items) |op| try std.testing.expect(isMutation(op.tag));
}

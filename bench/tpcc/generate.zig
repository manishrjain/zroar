const std = @import("std");
const model = @import("model.zig");

fn usage() void {
    std.debug.print(
        \\usage: tpcc-generate --out <directory> [options]
        \\
        \\  --warehouses N             default 10
        \\  --decks-per-warehouse N    default 100 (23 transactions/deck)
        \\  --seed N                   fixed default seed
        \\  --layout dense|packed|scattered|all
        \\  --smoke                    nonstandard small population for CI/local checks
        \\
        \\The output directory must not already exist. Generation writes a prebuilt
        \\posting-list snapshot plus separate read-only and write-only traces, using
        \\a temporary sibling and final atomic rename.
        \\
    , .{});
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    // Generation holds millions of posting memberships. Unlike the process
    // arena, this allocator reclaims one layout before the next one starts.
    const allocator = std.heap.smp_allocator;
    var out: ?[]const u8 = null;
    var warehouses: u32 = 10;
    var decks: u32 = 100;
    var seed: u64 = 0x5450_4343_5F35_3131;
    var selected_layout: ?model.Layout = null;
    var smoke = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            usage();
            return;
        } else if (std.mem.eql(u8, arg, "--smoke")) {
            smoke = true;
        } else if (std.mem.eql(u8, arg, "--out") or std.mem.eql(u8, arg, "--warehouses") or
            std.mem.eql(u8, arg, "--decks-per-warehouse") or std.mem.eql(u8, arg, "--seed") or
            std.mem.eql(u8, arg, "--layout"))
        {
            if (i + 1 >= args.len) return error.MissingOptionValue;
            i += 1;
            const value = args[i];
            if (std.mem.eql(u8, arg, "--out")) out = value else if (std.mem.eql(u8, arg, "--warehouses")) {
                warehouses = @intCast(try std.fmt.parseInt(u64, value, 0));
            } else if (std.mem.eql(u8, arg, "--decks-per-warehouse")) {
                decks = @intCast(try std.fmt.parseInt(u64, value, 0));
            } else if (std.mem.eql(u8, arg, "--seed")) {
                seed = try std.fmt.parseInt(u64, value, 0);
            } else {
                selected_layout = if (std.mem.eql(u8, value, "all")) null else std.meta.stringToEnum(model.Layout, value) orelse return error.BadLayout;
            }
        } else {
            std.debug.print("unknown argument: {s}\n", .{arg});
            usage();
            return error.UnknownArgument;
        }
    }
    if (out == null) {
        usage();
        return error.MissingOutputDirectory;
    }
    const scale = if (smoke) model.Scale.smoke(warehouses, decks) else model.Scale.canonical(warehouses, decks);
    std.debug.print("generating posting snapshot + separate read/write traces: W={d}, decks/W={d}, scale={s}\n", .{
        warehouses,
        decks,
        if (smoke) "smoke (nonstandard)" else "TPC-C population",
    });
    const started = std.Io.Clock.Timestamp.now(io, .awake);
    try model.generate(io, allocator, .{ .out_dir = out.?, .scale = scale, .seed = seed, .selected_layout = selected_layout });
    const elapsed_ms: u64 = @intCast(started.untilNow(io).raw.toMilliseconds());
    std.debug.print("published fixture at {s} in {d}.{d:0>3}s\n", .{ out.?, elapsed_ms / 1_000, elapsed_ms % 1_000 });
}

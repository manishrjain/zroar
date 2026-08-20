# zroar

64-bit roaring bitmaps in Zig, kept as one flat buffer: the serialized form
is the in-memory form, so opening a stored bitmap is O(1) — no parsing, no
per-container allocation. Array and bitmap containers over `u64` values, in
a little-endian, versioned format.

Faster than CRoaring's `roaring64` on CRoaring's own benchmarks, and by an
order of magnitude when bitmaps are opened from storage inside the measured
op — the case it is designed for. Numbers: [BENCHMARKS.md](BENCHMARKS.md).
Layout and rationale: [DESIGN.md](DESIGN.md).

## Using it

    zig fetch --save git+https://github.com/manishrjain/zroar

```zig
// build.zig
const zroar = b.dependency("zroar", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zroar", zroar.module("zroar"));
```

```zig
const zroar = @import("zroar");

var bm = try zroar.Bitmap.init(allocator);
defer bm.deinit();

_ = try bm.set(42);
_ = try bm.set(1 << 40);
assert(bm.contains(42));
assert(bm.getCardinality() == 2);

// Store: compact() canonicalizes and drops slack; the bytes are the format.
try bm.compact();
const bytes = try bm.toBufferCopy(allocator);
defer allocator.free(bytes);

// Open: O(1). Borrows `bytes`; copies only if the bitmap later grows.
var view = try zroar.Bitmap.fromBuffer(allocator, bytes);
defer view.deinit();

var it = view.iterator();
while (it.next()) |v| { ... }
```

Set algebra: `And`/`Or`/`fastOr` (materializing), `andInPlace`/`orInPlace`/
`andNotInPlace`, and fused `{and,or,andNot}Cardinality` that count without
materializing.

## Build and test

    zig build test          # unit + property tests (Debug and ReleaseSafe)
    zig build searchbench   # keys/array search microbench, no dependencies

## Benchmarks against CRoaring

    bench/fetch_croaring.sh                  # clone CRoaring + realdata into /tmp/CRoaring
    bench/run_all.sh -o results/run          # full suite, pinned; writes .tsv + report.md
    zig build bench -- <data_dir> [--suite realdata|synthetic|cold] [--out <tsv>]
    zig build difftest                       # differential test vs roaring64 (~2 s)
    zig build difftest -- --soak 300         # same, fresh seeds until time is up

`<data_dir>` is any `benchmarks/realdata/<set>` directory of the CRoaring
checkout. CRoaring elsewhere than /tmp/CRoaring: `-Dcroaring=<dir>`.

## Status

Zig 0.16. Format version 1 (the buffer's first two bytes; other versions are
refused). Buffers are trusted input — integrity checks belong a layer above.
No run containers, no 32-bit variant.

## License

Apache 2.0 — see [LICENSE](LICENSE).

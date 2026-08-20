# zroar - Serialized Roaring Bitmaps in Zig

zroar is a ground-up implementation of the popular roaring bitmaps library in a
serialized form. Zroar keeps all the msb keys and containers in a single flat
byte buffer, so the in-memory form of zroar is the serialized form, which can
then be stored to disk or sent over network as is. When opening a zroar buffer,
there's no parsing or per-container allocation. All read/write operations can be
done on the buffer immediately.

For benchmarks, we ported CRoaring benchmark suite to Zig. We expanded the
benchmarks into warm open and cold open. warm open is the bitmap already in its
in-memory format before benchmarking begins. The cold open adds a
deserialization step upfront (which is what you'd expect to do in a database
when reading a posting list stored as a byte array). For cold open, the
benchmarks test both the *frozen* and the *portable* serialization versions of
CRoaring. We also added OLTP synthetic dataset, which uses a zipfian
distribution of integers.

With its design, zroar performs 2x to 9x faster (geometric mean across test
cases) than CRoaring on both warm and cold open benchmarks. zroar runs up to
600x faster on serialization and deserialization. For cardinality estimations,
zroar's performance ranges from 1.2x to ~300x across warm and cold opens. 

In fact, zroar is faster in 339 of 360 benchmark cases run. The only case where
CRoaring decisively wins 2.5x against zroar is random interleaved insert/remove
(random writes). All benchmarks were done with the latest version of CRoaring
5.0 (released Aug 2026).

zroar is available under the Apache v2.0 [License][LICENSE]. Benchmark Report:
[BENCHMARKS](BENCHMARKS.md). Layout: [DESIGN](DESIGN.md).


| headline | # tests | vs CRoaring | vs frozen |
|---|---|---|---|
| realdata, bitmaps in memory (all data sets) | 36 | 2.15× | – |
| cold, every bitmap opened inside the call (all data sets) | 40 | 6.71× (portable) | 3.35× |
| synthetic, operations (Contains/Insert/Remove/Random; families weighted equally) | 132 | 2.16× | – |
| synthetic, Serialize + Deserialize | 56 | 622× (portable) | 267× |
| synthetic, all families | 188 | 8.91× (portable where a format is involved) | – |


| set | table | typical row | total time |
|---|---|---|---|
| census1881 | realdata (in memory) | 2.46× (0.88×–14.12×) | zroar 1.48 ms · r64 6.95 ms (4.71×) |
| census1881 | cold, opened portable | 11.82× (1.81×–108×) | zroar 2.46 ms · portable 11.47 ms (4.66×) |
| census1881 | cold, opened frozen | 4.72× (1.35×–25.14×) | zroar 2.46 ms · frozen 9.51 ms (3.87×) |
| census-income | realdata (in memory) | 2.25× (0.91×–13.98×) | zroar 12.43 ms · r64 52.94 ms (4.26×) |
| census-income | cold, opened portable | 5.12× (1.11×–156×) | zroar 12.69 ms · portable 57.45 ms (4.53×) |
| census-income | cold, opened frozen | 2.44× (0.95×–16.31×) | zroar 12.69 ms · frozen 53.62 ms (4.23×) |
| weather_sept_85 | realdata (in memory) | 2.14× (0.90×–13.35×) | zroar 32.40 ms · r64 108.05 ms (3.34×) |
| weather_sept_85 | cold, opened portable | 5.96× (1.03×–289×) | zroar 33.14 ms · portable 122.68 ms (3.70×) |
| weather_sept_85 | cold, opened frozen | 2.77× (0.90×–31.05×) | zroar 33.14 ms · frozen 109.91 ms (3.32×) |
| oltp | realdata (in memory) | 1.81× (0.87×–12.07×) | zroar 33.38 ms · r64 47.07 ms (1.41×) |
| oltp | cold, opened portable | 5.61× (1.06×–217×) | zroar 35.00 ms · portable 79.12 ms (2.26×) |
| oltp | cold, opened frozen | 3.96× (0.94×–86.69×) | zroar 35.00 ms · frozen 62.28 ms (1.78×) |

## Why zroar and why is it faster?

zroar was originally designed for systems which keep their posting lists /
inverted indexes on disk, or have to send it over network. The design goal for
zroar is to ensure that the serialized form can readily do both read and write
operations without any performance penalty of a deserialization step.

However, zroar has proven to be more efficient than CRoaring even for warm
purely in-memory operations, with no deserialization step involved. I think this
design can be applied to a Roaring Bitmaps library in any language to achieve
significant performance boost.

Roaring Bitmaps contain bitmap and array containers (depending on the
cardinality of the container). The MSB 48-bits (high48) are stored in an index,
which points to the container. This container then stores the integers holding
their LSB 16-bits. Depending upon how many integers are present, the container
could be a sorted 16-bits unsigned int array (low16), or a bitmap.

CRoaring allocates memory for each of these containers, holding the high48 in an
adaptive radix tree (ART), holding memory pointers to these containers. Reaching
a container means following the ART, where each node is a single byte of the
high48. That'd be 7 memory dereferences (high48 = 6 bytes + container pointer)
to reach the container.

zroar flips that design by allocating one memory buffer, keeping `(high48,
offset)` pairs in the front, where the offset stores the container offset in the
same buffer. The container in turn stores the size of container (u16), type of
container (array or bitmap, u16), and cardinality (number of integers container
is holding, u32).

Note: zroar does not support a third, run container (supported by CRoaring). The
run container adds significant complexity (expecting 1000+ LOC) and the
benefit/applicability to database systems isn't clear, which is what I'm using
zroar for. This could change in future if needs evolve.

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

// For long term storage (database), you might want to run an
// optional step of 'compact', which achieves the smallest possible size.
try bm.compact(); // OPTIONAL

const bytes = try bm.toBuffer(allocator);
// write to disk or ship bytes over the network.

// Open: O(1). With .borrow, `bytes` is never touched; the first
// mutation copies it out. Pass .own to hand the buffer over instead.
var bm2 = try zroar.Bitmap.fromBuffer(allocator, bytes, .borrow);
defer bm2.deinit();

var it = bm2.iterator();
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
    zig build difftest                       # differential test vs roaring64 (~2 s) for correctness verification
    zig build difftest -- --soak 300         # same, fresh seeds until time is up

`<data_dir>` is any `benchmarks/realdata/<set>` directory of the CRoaring
checkout. CRoaring elsewhere than /tmp/CRoaring: `-Dcroaring=<dir>`.

## Status

Zig 0.16. Format version 1 (the buffer's first two bytes; other versions are
refused). Buffers are trusted input — integrity checks belong a layer above.
No run containers, no 32-bit variant.

## zroar Design Advantages Over CRoaring

1. **No pointer chasing**

In CRoaring, reaching a container means walking the ART over the high64 nodes,following the ART, where each node is a
single byte of the high48. That'd be 7 memory dereferences (6 bytes from high48
and container pointer) to reach the container. Every hop is dependent on the
previous data, and each could be a cache-miss.

zroar has no pointers. All the high48 keys are kept sorted, so we can binary
search (+ scan) over them without any pointer chasing, and most likely using the
same cache lines that were already touched.

2. **Data locality*

In CRoaring, container n and n+1 live wherever malloc happens to put them, which
might be pages apart. The hardware prefetcher sees no pattern.

In zroar, all the containers are colocated tightly (even accounting for a little
bit of slack kept in array containers to grow). Reading the containers
can just walk forward in the same underlying buffer, using memory-prefetching to
keep operations efficient.

3. **No small allocations**

CRoaring bitmaps allocates memory per container, which leads to lots of small
allocations, one per container, then many times as the container grows.

zroar grows by remap/realloc of the entire buffer. This reduces the number of
allocations and avoids memory fragmentation.

Though, this is also the cause for where zroar slightly lags CRoaring -- random
inserts. If a container in the middle of the buffer grows, then to expand that
container, zroar has to expand the buffer and move the containers on the right
side (think inserting in the middle of an array), while CRoaring only has to
expand that one container's memory.

zroar reduces that cost by proactively moving the expanding container to the end
of the buffer to make future expansions cheaper. It further uses remap to
request the memory allocator to update the size of the buffer without moving
memory making expansion cost zero, whenever possible.

4. **No serialization / deserialization, frozen/portable, warm/cold**

CRoaring has two deserialization formats: frozen and portable. Frozen
technically is a *cheaper, fixed* view into the serialized format. While frozen
format might seem similar to zroar, it still mallocs O(num containers) to make
the serialized format readable. Being a view, it comes with the limitation that
it does NOT accept any writes. For that, you'd have to re-create the in-memory
form, paying the full cost of deserialization.

The portable format generates a full writeable in-memory form and also requires
full deserialize to use.

zroar's in-memory format is the serialized format. And the `fromBuffer` is just
a pointer cast and store in the `Bitmap` struct, which takes nanoseconds, which
makes zroar 600x faster on average than CRoaring.

zroar does have a `compact` API, which can be optionally used to make the bitmap
as small as possible (say before long term storage), removing any paddings that
might exist in array containers (to support growth). In this form, zroar mostly
takes <5% extra space compared to CRoaring frozen and portable formats.


| set | bitmaps | values | zroar | r64 portable | run-container saving | r64 frozen |
|---|---|---|---|---|---|---|
| census1881 | 200 | 1,003,861 | 2.0 MB | 1.8 MB (0.93× of zroar) | 6% | 1.9 MB (0.97×) |
| census-income | 200 | 6,922,021 | 2.3 MB | 2.1 MB (0.93× of zroar) | 5% | 2.2 MB (0.95×) |
| weather_sept_85 | 200 | 12,870,627 | 8.6 MB | 8.3 MB (0.96× of zroar) | 1% | 8.3 MB (0.97×) |
| oltp | 200 | 2,486,531 | 5.9 MB | 5.0 MB (0.85× of zroar) | 0% | 5.7 MB (0.97×) |


5. Simpler, smaller codebase

zroar codebase is also simple and much smaller. The main logic (excluding tests
and benchmarking code) is ~2000 lines of code, compared to CRoaring's 17,000
lines of code for the 64-bit version (excluding the 32-bit version, tests,
bench). In CRoaring, just roaring64.c and art.c itself is >4K LOC.

This is due to the simpler design of zroar which avoids the need for a complex
adaptive radix tree (ART) implementation, serialization / deserialization,
frozen views which accommodate the ART, two container types instead of three,
and portable SIMD loops which enjoy built-in support from Zig.

## zroar Downsides Compared to CRoaring

This is purely a Zig only library. It does not support the portable serialized
format of CRoaring, though that could be added if required.

zroar only supports 64-bit integers currently (I don't have a need for 32-bit
ints). These are omissions for the sake of simplicity than any limitation in the
design of zroar. Over time as needs arise, these features could be added.

The only case where CRoaring decisively wins 2.5x against zroar is random
interleaved insert/remove (random writes). This case requires zroar to
constantly move memory slowing it down, while CRoaring can just expand or delete
individual containers. A way to alleviate this is to sort the integers before
passing to zroar. On sorted inserts, zroar is 1.3x-4x faster, with its advantage
growing when many integers end up in the same container.


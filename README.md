# zroar

64-bit roaring bitmaps in Zig, kept as one flat buffer so that opening a
serialized bitmap is O(1). See DESIGN.md.

## Build and test

    zig build test          # unit + property tests
    zig build searchbench   # keys/array search microbench, no dependencies

## Benchmarks against CRoaring (roaring64)

    bench/fetch_croaring.sh   # clones CRoaring (source + realdata) into /tmp/CRoaring
    zig build bench -- <data_dir> [--oltp|--oltp-random] \
        [--suite realdata|synthetic|cold]... [-b <substring>] [--time <ms>] [--out <tsv>]
    bench/run_all.sh          # standard set -> bench/results/*.tsv -> BENCHMARKS.md
    zig build difftest        # zroar vs roaring64 differential test

`<data_dir>` is any `benchmarks/realdata/<set>` directory of the CRoaring
checkout (default: census1881). Elsewhere than /tmp/CRoaring: `-Dcroaring=<dir>`.

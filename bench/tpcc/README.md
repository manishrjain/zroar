# TPC-C-derived uint64 secondary-index benchmark

This directory contains a deterministic dataset generator and replay benchmark
for bitmap implementations used behind SQL OLTP secondary indexes. It is
**derived from TPC-C 5.11**, but it is not a TPC-C implementation, is not
comparable to published TPC-C results, and must not be described using tpmC.

The goal is narrower: give zroar and CRoaring the same portable posting lists
and expected answers while varying primary-key locality in a controlled way.
Posting-list construction/maintenance and SELECT-style reads are deliberately
separate workloads.

## Mental model

A secondary-index posting list is the set of table primary keys matching one
indexed value. For example:

```text
ORDER.customer_id = 42  ->  {order PK 1001, order PK 1057, order PK 1098}
```

The benchmark lifecycle mirrors an OLTP storage engine:

```text
row writes / index maintenance
        |
        v
prebuilt posting-list snapshot (postings.bin)
        |
        +---- read workload: probe/intersect/union only; snapshot never changes
        |
        `---- write workload: insert/remove/move only; measured separately
```

The read timer starts only after zroar or CRoaring has materialized the
snapshot in its native representation. The separately reported `build ms`
column is the materialization cost; it is not included in read ns/transaction
or read throughput.

## Commands

Generate the canonical ten-warehouse fixture (23,000 transactions):

```sh
zig build tpcc-generate -- --out /tmp/zroar-tpcc
```

Run the default read-only workload for every key layout and lifecycle profile:

```sh
zig build -Doptimize=ReleaseFast tpcc-bench -- /tmp/zroar-tpcc
```

Run posting-list maintenance separately, or request both result sets:

```sh
zig build -Doptimize=ReleaseFast tpcc-bench -- /tmp/zroar-tpcc \
  --workload write
zig build -Doptimize=ReleaseFast tpcc-bench -- /tmp/zroar-tpcc \
  --workload all
```

Narrow a run when iterating:

```sh
zig build -Doptimize=ReleaseFast tpcc-bench -- /tmp/zroar-tpcc \
  --layout scattered --workload read --profile serialized --samples 7
```

The nonstandard smoke scale is intended only for CI and local correctness
checks:

```sh
zig build tpcc-generate -- --out /tmp/zroar-tpcc-smoke \
  --smoke --warehouses 1 --decks-per-warehouse 1
zig build -Doptimize=ReleaseFast tpcc-bench -- /tmp/zroar-tpcc-smoke \
  --samples 1
```

The generator refuses to overwrite an existing directory. It writes a
uniquely named temporary sibling and publishes the complete dataset with a
final rename. If generation is interrupted, retry the same command: the retry
uses a new staging directory. Once no generator is running, abandoned sibling
directories named `<output>.tmp-*` can be removed to reclaim disk space.

Generation first collects each posting as neutral keys, sorts it once, and
exports sorted `u64` keys. It then bulk-loads those keys into resident zroar
bitmaps to apply the untimed write trace efficiently. Both zroar and CRoaring
load the same neutral exported representation during the benchmark. The
generator reports each layout and phase, population progress by warehouse,
zroar materialization progress, and write-trace progress in roughly 10%
increments with elapsed time and ETA.

As a reference point, the canonical three-layout command completed in about
150 seconds on the development machine. Dense and packed each took under five
seconds; scattered-key write-trace generation accounted for roughly 140
seconds. Exact time varies with CPU and memory performance.

## Population and transaction model

Canonical generation uses the TPC-C 5.11 population constants relevant to the
indexed tables:

- 10 districts per warehouse
- 3,000 customers and initial orders per district
- 900 initial `NEW_ORDER` rows per district
- 100,000 stock rows per warehouse
- 5–15 order lines per order

Each warehouse receives 100 independently shuffled copies of the standard
23-transaction deck: ten New-Order, ten Payment, one Order-Status, one
Delivery, and one Stock-Level. The per-warehouse decks are then globally
shuffled into deterministic, single-threaded read and write projections.
Payment and
Order-Status use the approximately 60% last-name path; Payment includes the
approximately 15% remote-customer path; New-Order includes the approximately
1% invalid-item rollback path.

The read projection contains only `probe`, `intersect`, and
`union_cardinality`. The write projection contains only `insert`, `remove`,
and `move`. Generation and replay reject an artifact that violates that split.
Neither projection models database locking, abort conflicts, page management,
SQL execution, row materialization, network service time, or client
think/keying time.

## Indexed tables

The neutral posting-list catalog covers:

| Table | Indexed values |
| --- | --- |
| `CUSTOMER` | warehouse, district, last name |
| `ORDER` | warehouse, district, customer, carrier/null |
| `ORDER_LINE` | warehouse, district, order, item, delivered flag |
| `STOCK` | warehouse, item, exact quantity |
| `NEW_ORDER` | warehouse, district |

Transactions are projected onto separate read and write traces. For example,
the read side of New-Order probes customer and stock postings. Its write side
adds `ORDER`, `NEW_ORDER`, and `ORDER_LINE` memberships and moves a stock row
between exact-quantity lists. Delivery's write side removes queue membership
and moves carrier/delivery memberships. Payment has index lookups in the read
trace but does not invent index writes for columns it leaves unchanged.

Stock-Level's SQL join is not presented as a same-row bitmap intersection.
The trace intersects warehouse and quantity postings on `STOCK`, then probes
the item ids supplied by the logical recent-order join. Join execution itself
is outside this bitmap benchmark.

## Mandatory primary-key layouts

Each generation emits three independent directories with identical logical
rows and transactions:

- `dense`: consecutive table-local row ids, representing an auto-increment key.
- `packed`: a documented table-specific packing of warehouse/district/entity
  fields, representing locality-preserving composite identifiers.
- `scattered`: a fixed-seed SplitMix64 bijection over each table's dense id,
  representing uniformly scattered uint64 primary keys without collisions.

Results are reported separately. There is intentionally no aggregate score
that could hide a layout where one implementation behaves poorly.

## Lifecycle profiles and timing

`--workload read` is the default. It constructs every bitmap before timing and
then executes an immutable trace. The benchmark asserts that the trace has no
insert, remove, or move operation, and the final state digest must equal the
initial snapshot digest.

`--workload write` starts from the same snapshot but executes only index
maintenance. There are no SELECT/probe/intersection/union operations in its
timer. Use `--workload all` to report both without combining them into one
score.

`resident` keeps the already-materialized posting lists open in memory during
the chosen workload.

`serialized` constructs each implementation's native persistent bytes before
timing. In the read workload, every touched list is opened and queried without
being rewritten, so `rewritten bytes` must be zero. In the write workload,
mutations serialize replacement buffers and report their rewritten bytes.
Filesystem syscalls, disk latency, compression by a surrounding storage
engine, and page-cache behavior are intentionally excluded so the comparison
isolates the bitmap formats and algorithms.

One warmup precedes the requested samples (seven by default). Library order is
alternated between samples and the starting library changes across cases. The
median full-trace time is used for throughput and ns/transaction. Per-type
p50/p95 values come from the final sample and are diagnostic; they are not
combined into a score. State construction is timed and reported separately.

Both adapters use the C allocator. CRoaring's initial posting lists receive
`runOptimize`; no result depends on container representation. Every operation
result and the final sorted-state digest must match the generator's reference
model or the run fails.

## Portable artifact format

Each layout directory contains:

- `manifest.json`: format/version, scale, seed, disclaimer, counts, catalog,
  initial/final digests, and SHA-256 checksums.
- `postings.bin`: `ZTPCCP01`, version/catalog headers, then little-endian
  `(index id, normalized value, cardinality, sorted uint64 keys)` records.
- `read-trace.bin`: `ZTPCCT01`, immutable read operations and the unchanged
  snapshot digest.
- `write-trace.bin`: `ZTPCCT01`, posting-list maintenance operations and the
  expected updated-state digest.

The replay parses bounds and enum ids, rejects trailing/truncated data, and
checks all three binary files against the manifest. Artifacts are generated
locally and should not be committed.

## Reproducibility and interpretation

For a publishable comparison, record the repository commits, Zig/compiler and
CRoaring versions, target CPU/features, generator command and seed, fixture
manifest, benchmark command, host/kernel, power policy, and whether the host
was isolated. Use the canonical scale, all layouts, both profiles, and the
default or greater sample count. Publish every case, including losses.

This workload is useful for comparing uint64 bitmap secondary-index behavior;
it is not sufficient to claim SQL OLTP performance. A database result also
depends on its B-tree/LSM/hash indexes, optimizer, buffer manager, WAL,
concurrency control, recovery, and storage device.

Primary references:

- TPC-C 5.11 specification:
  https://www.tpc.org/tpc_documents_current_versions/pdf/tpc-c_v5.11.0.pdf
- TPC Fair Use quick reference:
  https://www.tpc.org/TPC_Documents_Current_Versions/pdf/Fair_Use_Quick_Reference_v1.0.0.pdf
- BenchBase (useful as an independent behavioral cross-check, not a runtime
  dependency): https://github.com/cmu-db/benchbase

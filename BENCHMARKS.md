# zroar vs CRoaring roaring64

Generated 2026-08-17 by `bench/report.py` from `zig build bench --out` files (Zig 0.16.0, CRoaring 5.0.0, ReleaseFast). Ratios; absolute times are in the .tsv files.

Measured on AMD Ryzen 9 5950X 16-Core Processor; governor powersave, boost on, SMT on, pinned to CPU(s) 3.
Measured on AMD Ryzen 9 5950X 16-Core Processor; governor performance, boost on, SMT on, pinned to CPU(s) 3.

How to read this:

- Every cell is a speed ratio: **CRoaring's time ÷ zroar's time** on the same
  benchmark. `2.93×` means zroar took a third of the time (zroar 2.93× faster);
  `0.49×` means zroar took twice as long (zroar 2× slower). **>1 = zroar faster.**
- The benchmarks are CRoaring's own, ported line for line: `bench.cpp`'s 64-bit
  rows over the per-file bitmaps of each data set (section *realdata*), and
  `synthetic_bench.cpp`'s r64 rows over its shape grid (section *synthetic*).
- Section *cold* is ours: the realdata rows again, but every bitmap is opened
  from its serialized bytes inside the timed call — what a store does per
  query. Plus `MixedOLTP`: open one posting list, 90 point reads, 10 appends,
  close.
- Where bitmaps are opened or written, CRoaring has two formats and both get
  a column, written `portable / frozen`. *Portable* is its interchange format
  (a full parse to open). *Frozen* is its in-memory layout written out and
  viewed in place, read-only — the same kind of format as zroar's. `MixedOLTP`
  writes after opening, so it has no frozen column.
- zroar has no run containers. Data sets where run containers shrink
  CRoaring's bitmaps a lot are left out of the standard set; the saving is
  shown per set below.

## Data sets

| set | files | values | zroar | r64 portable | run-container saving | r64 frozen |
|---|---|---|---|---|---|---|
| census1881 | 200 | 1,003,861 | 2.4 MB | 1.8 MB (0.76× of zroar) | 6% | 1.9 MB (0.80×) |
| census-income | 200 | 6,922,021 | 2.5 MB | 2.1 MB (0.87× of zroar) | 5% | 2.2 MB (0.89×) |
| weather_sept_85 | 200 | 12,870,627 | 9.2 MB | 8.3 MB (0.90× of zroar) | 1% | 8.3 MB (0.90×) |
| oltp | 200 | 2,486,531 | 7.4 MB | 5.0 MB (0.68× of zroar) | 0% | 5.7 MB (0.77×) |
| oltp-random | 200 | 2,505,315 | 76.5 MB | 52.6 MB (0.69× of zroar) | 0% | 102.5 MB (1.34×) |

## realdata — CRoaring's bench.cpp rows, bitmaps already in memory

Both libraries hold the data set's 200 bitmaps in memory (built once, before timing); each cell is CRoaring's time ÷ zroar's for that benchmark. One column per data set.

| benchmark | census1881 | census-income | weather_sept_85 | oltp | oltp-random |
|---|---|---|---|---|---|
| SuccessiveIntersection64 | 0.87× | 1.30× | 1.53× | 1.41× | 2.43× |
| SuccessiveIntersectionCardinality64 | 1.18× | 1.42× | 1.35× | 1.16× | 4.89× |
| SuccessiveUnionCardinality64 | 3.08× | 1.50× | 1.40× | 1.33× | 9.96× |
| SuccessiveDifferenceCardinality64 | 2.22× | 1.47× | 1.39× | 1.24× | 7.59× |
| SuccessiveUnion64 | 0.47× | 0.68× | 0.78× | 0.66× | 1.19× |
| RandomAccess64 | 1.74× | 2.25× | 2.24× | 1.66× | 0.74× |
| ToArray64 | 1.22× | 1.23× | 1.04× | 0.87× | 11.85× |
| IterateAll64 | 5.82× | 8.90× | 7.35× | 4.44× | 11.27× |
| ComputeCardinality64 | 10.17× | 11.40× | 11.92× | 10.37× | 15.85× |

zroar faster than CRoaring on 38 of 45 cells.

## cold — the same rows, but every bitmap is opened inside the timed call

Cells read `portable / frozen`: CRoaring's time opening its bitmaps from that format and doing the work, ÷ zroar's time doing the same from its buffer.

| benchmark | census1881 | census-income | weather_sept_85 | oltp | oltp-random |
|---|---|---|---|---|---|
| ColdSuccessiveIntersection64 | 10.59× / 2.69× | 1.87× / 1.37× | 2.17× / 1.57× | 2.39× / 1.80× | 13.70× / 6.95× |
| ColdSuccessiveIntersectionCardinality64 | 19.52× / 4.52× | 2.83× / 1.59× | 2.46× / 1.47× | 2.24× / 1.57× | 29.41× / 13.60× |
| ColdSuccessiveUnionCardinality64 | 19.52× / 5.86× | 2.86× / 1.66× | 2.52× / 1.51× | 2.39× / 1.75× | 34.46× / 18.36× |
| ColdSuccessiveDifferenceCardinality64 | 19.25× / 5.19× | 2.86× / 1.63× | 2.49× / 1.51× | 2.32× / 1.66× | 32.39× / 16.45× |
| ColdSuccessiveUnion64 | 0.67× / 0.50× | 0.92× / 0.72× | 0.97× / 0.78× | 0.81× / 0.72× | 1.84× / 1.42× |
| ColdRandomAccess64 | 90.13× / 17.91× | 55.84× / 7.11× | 140× / 14.21× | 256× / 100× | 23,589× / 8,560× |
| ColdToArray64 | 3.44× / 3.20× | 1.31× / 1.24× | 1.18× / 1.04× | 2.80× / 1.61× | 56.27× / 27.78× |
| ColdIterateAll64 | 7.97× / 7.64× | 7.55× / 7.53× | 6.66× / 6.55× | 6.24× / 5.72× | 99.24× / 50.83× |
| ColdComputeCardinality64 | 144× / 32.77× | 278× / 30.38× | 356× / 39.83× | 103× / 45.90× | 176× / 74.46× |
| MixedOLTP | 1.76× | 4.11× | 5.67× | 2.39× | 9.10× |

zroar faster than CRoaring portable on 46 of 50 cells.
zroar faster than CRoaring frozen on 41 of 45 cells.

## synthetic — CRoaring's synthetic_bench.cpp rows, generated shapes

- Each shape is `count` values spaced `step` apart (their `r64X/count/step`).
- Step 1 packs everything into one dense container; from step 2^16 up every value sits in its own container under its own key.
- Cells are again CRoaring's time ÷ zroar's, per operation for the Contains rows and per whole build/serialize otherwise.
- At step 2^48 `count × step` overflows past 65,536 values (in C too), so those cells re-insert the same 65,536 values.

Steps 2^16 and up behave alike, so they share one column showing the range across them (`--full` prints every step). Serialize and Deserialize cells read `portable / frozen`.

| benchmark | count | step 1 | step 2^8 | steps 2^16–2^48 |
|---|---|---|---|---|
| ContainsHit | 1,000 | 1.24× | 1.31× | 0.92× |
| ContainsHit | 10,000 | 1.73× | 1.11× | 0.64×–1.07× |
| ContainsHit | 100,000 | 2.48× | 1.06× | 0.51×–0.80× |
| ContainsHit | 1,000,000 | 1.87× | 0.97× | 0.61×–0.78× |
| ContainsMiss | 1,000 | 1.24× | 1.35× | 0.85× |
| ContainsMiss | 10,000 | 1.74× | 1.09× | 0.66×–0.77× |
| ContainsMiss | 100,000 | 2.53× | 1.04× | 0.44×–0.69× |
| ContainsMiss | 1,000,000 | 1.91× | 0.96× | 0.45×–0.70× |
| Insert | 1,000 | 0.92× | 1.27× | 2.65× |
| Insert | 10,000 | 1.66× | 1.40× | 2.41× |
| Insert | 100,000 | 2.59× | 1.32× | 1.51× |
| Insert | 1,000,000 | 2.91× | 1.58× | 0.71×–0.88× |
| Remove | 1,000 | 1.89× | 1.79× | 2.88× |
| Remove | 10,000 | 14.25× | 1.97× | 2.49× |
| Remove | 100,000 | 6.48× | 2.19× | 1.56×–2.45× |
| Remove | 1,000,000 | 6.31× | 2.16× | 0.34×–2.25× |
| Serialize | 1,000 | 1.99× / 2.01× | 4.13× / 3.73× | 42.76×–80.27× / 29.70× |
| Serialize | 10,000 | 1.64× / 1.46× | 2.53× / 2.08× | 41.44×–80.41× / 29.32× |
| Serialize | 100,000 | 1.61× / 1.27× | 1.94× / 1.62× | 42.95×–81.81× / 30.45× |
| Serialize | 1,000,000 | 1.30× / 1.26× | 1.94× / 1.55× | 14.43×–82.34× / 10.51×–32.36× |
| Deserialize | 1,000 | 5.96× / 2.38× | 14.61× / 5.52× | 3,034×–4,054× / 1,576× |
| Deserialize | 10,000 | 50.24× / 2.40× | 136× / 49.72× | 31,476×–40,929× / 14,977× |
| Deserialize | 100,000 | 102× / 3.78× | 1,376× / 654× | 259,448×–404,372× / 94,147×–149,618× |
| Deserialize | 1,000,000 | 807× / 17.56× | 13,967× / 6,800× | 260,116×–4,523,467× / 99,308×–1,581,697× |

Random values under ten bitmasks (numbered as CRoaring numbers them). Masks 1, 2, 3, 5, 6 and 8 have no bits below bit 16, so every value lands in its own container:

| benchmark \ mask | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 |
|---|---|---|---|---|---|---|---|---|---|---|
| ContainsRandom | 1.51× | 1.25× | 1.21× | 1.14× | 0.87× | 1.20× | 1.57× | 1.13× | 2.01× | 1.34× |
| InsertRemoveRandom | 1.59× | 0.38× | 0.31× | 0.34× | 0.96× | 0.39× | 0.35× | 1.21× | 0.41× | 1.40× |

zroar faster than CRoaring (portable where a format is involved) on 133 of 188 rows.
zroar faster than CRoaring frozen on 56 of 56 rows.

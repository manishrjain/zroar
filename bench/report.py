#!/usr/bin/env python3
"""Render the bench's --out files as one Markdown report.

    zig build bench -- <data_dir> --out results/census1881.tsv
    zig build bench -- --oltp --out results/oltp.tsv
    zig build bench -- --suite synthetic --out results/synthetic.tsv
    bench/report.py results/*.tsv > results/report.md

Every cell is a ratio, CRoaring's time over zroar's, so >1 means zroar is
faster. The synthetic grid is condensed by default: the steps from 2^16 up
behave alike (one value per key), so they are shown as a range; --full prints
every cell. Absolute times (microseconds per operation) stay in the .tsv files.
"""

import argparse
import datetime
import math
import os
import sys
from collections import OrderedDict, defaultdict

REALDATA_ROWS = [
    "SuccessiveIntersection64",
    "SuccessiveIntersectionCardinality64",
    "SuccessiveUnionCardinality64",
    "SuccessiveDifferenceCardinality64",
    "SuccessiveUnion64",
    "RandomAccess64",
    "ToArray64",
    "IterateAll64",
    "ComputeCardinality64",
]
COLD_ROWS = ["Cold" + r for r in REALDATA_ROWS] + ["MixedOLTP"]

COUNTS = [1000, 10000, 100000, 1000000]
# Steps as the bench names them: 1, 2^8, ... 2^48 (CRoaring's rows spell the
# integer out; ours write the power of two).
STEPS = ["1", "2^8", "2^16", "2^24", "2^32", "2^40", "2^48"]
STEP_LABELS = STEPS
STEPPED = ["ContainsHit", "ContainsMiss", "Insert", "Remove", "Serialize", "Deserialize"]
MASKED = ["ContainsRandom", "InsertRemoveRandom"]

# Column order for the per-data-set tables; anything else follows, by name.
DATASET_ORDER = ["census1881", "census-income", "weather_sept_85", "oltp"]

PREAMBLE = """\
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
  writes after opening, which a frozen view does not allow, so its frozen
  column is `frozen_view` plus `roaring64_bitmap_copy`: the writable bitmap a
  frozen-format user has to make first.
- Sizes and serialization are measured on what a store would write: zroar's
  buffers are compacted first (`compact()`, no growth slack), matching
  CRoaring's exact portable encoding and the `shrink_to_fit` its frozen
  format requires. This happens at setup, outside every timing.
- zroar has no run containers. Data sets where run containers shrink
  CRoaring's bitmaps a lot are left out of the standard set; the saving is
  shown per set below.
"""


def parse(path):
    meta, rows = {}, {}
    with open(path) as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if parts[0] == "meta":
                meta[parts[1]] = parts[2]
            elif parts[0] == "row":
                _, suite, name, impl, us = parts
                rows.setdefault(name, {"suite": suite})[impl] = float(us)
    return meta, rows


def ratio(cell, impl):
    if cell is None or impl not in cell or "zroar" not in cell:
        return None
    return cell[impl] / cell["zroar"]


def fmt(r):
    if r is None:
        return "–"
    if r >= 1000:
        return f"{r:,.0f}×"
    if r >= 100:
        return f"{r:.0f}×"
    return f"{r:.2f}×"


def fmt_range(rs):
    rs = [r for r in rs if r is not None]
    if not rs:
        return "–"
    lo, hi = min(rs), max(rs)
    if hi / lo < 1.15:
        return fmt(lo)
    return f"{fmt(lo)}–{fmt(hi)}"


def geomean(rs):
    rs = [r for r in rs if r is not None and r > 0]
    if not rs:
        return None
    return math.exp(sum(math.log(r) for r in rs) / len(rs))


def score(cells, impl):
    """Geomean of the ratios over `cells` for `impl`, with the spread: "2.1× (0.5–10×)"."""
    rs = [ratio(c, impl) for c in cells]
    rs = [r for r in rs if r is not None]
    if not rs:
        return None
    return f"{fmt(geomean(rs))} ({fmt(min(rs))}–{fmt(max(rs))})"


def fmt_us(us):
    if us < 1:
        return f"{us * 1000:.0f} ns"
    if us < 1000:
        return f"{us:.1f} µs"
    if us < 1e6:
        return f"{us / 1000:.2f} ms"
    return f"{us / 1e6:.2f} s"


def totals(cells, impls):
    """Summed time over `cells` per implementation, and the ratio of the sums
    to zroar's: "zroar 2.4 ms · r64 7.9 ms (3.3×)". Only over cells that have
    every implementation asked for, so the sums cover the same rows."""
    cells = [c for c in cells if c is not None and all(i in c for i in ("zroar",) + tuple(impls))]
    if not cells:
        return None
    zr = sum(c["zroar"] for c in cells)
    parts = [f"zroar {fmt_us(zr)}"]
    for impl, label in impls.items():
        t = sum(c[impl] for c in cells)
        parts.append(f"{label} {fmt_us(t)} ({fmt(t / zr)})")
    return " · ".join(parts)


def both(cell):
    p, f = ratio(cell, "r64"), ratio(cell, "r64_frozen")
    return fmt(p) if f is None else f"{fmt(p)} / {fmt(f)}"


def bytes_h(n):
    n = int(n)
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="+", help=".tsv files written by the bench's --out")
    ap.add_argument("--full", action="store_true", help="every synthetic cell, not the condensed grid")
    args = ap.parse_args()

    runs = OrderedDict()  # dataset -> (meta, rows), realdata/cold rows keyed by dataset
    synthetic = {}
    versions = set()
    machines = OrderedDict()  # ordered set of the conditions seen across files
    for path in args.files:
        meta, rows = parse(path)
        versions.add((meta.get("zig", "?"), meta.get("croaring", "?")))
        machines[tuple(meta.get(k, "unknown") for k in ("cpu", "governor", "boost", "smt", "cpus"))] = None
        ds = meta.get("dataset", os.path.basename(path))
        per_ds = {n: r for n, r in rows.items() if r["suite"] in ("realdata", "cold")}
        if per_ds:
            if ds in runs:
                runs[ds][1].update(per_ds)
            else:
                runs[ds] = (meta, per_ds)
        for n, r in rows.items():
            if r["suite"] == "synthetic":
                synthetic[n] = r

    def order(ds):
        return (DATASET_ORDER.index(ds), "") if ds in DATASET_ORDER else (len(DATASET_ORDER), ds)
    runs = OrderedDict(sorted(runs.items(), key=lambda kv: order(kv[0])))

    out = []
    p = out.append
    p("# zroar vs CRoaring roaring64")
    p("")
    vs = ", ".join(f"Zig {z}, CRoaring {c}" for z, c in sorted(versions))
    p(f"Generated {datetime.date.today()} by `bench/report.py` from `zig build bench --out` "
      f"files ({vs}, ReleaseFast). Ratios; absolute times (µs) are in the .tsv files.")
    p("")
    for m in machines:
        p(f"Measured on {m[0]}; governor {m[1]}, boost {m[2]}, SMT {m[3]}, pinned to CPU(s) {m[4]}.")
    p("")
    p(PREAMBLE)

    # Summary: geometric means of the ratios. A geomean lets a 2× win and a 2×
    # loss cancel, which an average of ratios does not; the spread beside each
    # keeps it from hiding a bad cell. First the headline numbers — one per
    # table, over every data set — then the same per data set and per
    # synthetic family.
    FORMAT_FAMILIES = ("Serialize", "Deserialize")
    if runs or synthetic:
        p("## Summary")
        p("")
        p("Geometric means of the ratios (CRoaring's time ÷ zroar's; above 1 = "
          "zroar faster), every cell counting the same. *Headline*: one number "
          "per table, over every data set. Then the same per data set and per "
          "synthetic family, each with its min–max and with *total time*: each "
          "library's time summed over the rows and the ratio of the sums, where "
          "the expensive rows dominate as they would in a workload. An overview "
          "only: the tables further down show where the wins and losses are.")
        p("")
        p("| headline | cells | vs CRoaring | vs frozen |")
        p("|---|---|---|---|")
        if runs:
            warm_all = [rows.get(n) for _, rows in runs.values() for n in REALDATA_ROWS]
            cold_all = [rows.get(n) for _, rows in runs.values() for n in COLD_ROWS]
            warm_all = [c for c in warm_all if c is not None]
            cold_all = [c for c in cold_all if c is not None]
            p(f"| realdata, bitmaps in memory (all data sets) | {len(warm_all)} | "
              f"{fmt(geomean([ratio(c, 'r64') for c in warm_all]))} | – |")
            p(f"| cold, every bitmap opened inside the call (all data sets) | {len(cold_all)} | "
              f"{fmt(geomean([ratio(c, 'r64') for c in cold_all]))} (portable) | "
              f"{fmt(geomean([ratio(c, 'r64_frozen') for c in cold_all]))} |")
        if synthetic:
            def family_scores(impl, fams):
                out_ = []
                for fam in fams:
                    cells = [r for n, r in synthetic.items() if n.split("/")[0] == fam]
                    g = geomean([ratio(c, impl) for c in cells])
                    if g is not None:
                        out_.append(g)
                return out_
            ops = [f for f in STEPPED + MASKED if f not in FORMAT_FAMILIES]
            n_ops = sum(1 for n in synthetic if n.split("/")[0] in ops)
            n_fmt = sum(1 for n in synthetic if n.split("/")[0] in FORMAT_FAMILIES)
            p(f"| synthetic, operations (Contains/Insert/Remove/Random; families weighted equally) | {n_ops} | "
              f"{fmt(geomean(family_scores('r64', ops)))} | – |")
            p(f"| synthetic, Serialize + Deserialize | {n_fmt} | "
              f"{fmt(geomean(family_scores('r64', FORMAT_FAMILIES)))} (portable) | "
              f"{fmt(geomean(family_scores('r64_frozen', FORMAT_FAMILIES)))} |")
            p(f"| synthetic, all families | {n_ops + n_fmt} | "
              f"{fmt(geomean(family_scores('r64', STEPPED + MASKED)))} (portable where a format is involved) | – |")
        p("")
    if runs:
        p("| set | table | typical row | total time |")
        p("|---|---|---|---|")
        for ds, (_, rows) in runs.items():
            warm = [rows.get(n) for n in REALDATA_ROWS]
            cold = [rows.get(n) for n in COLD_ROWS]
            p(f"| {ds} | realdata (in memory) | {score(warm, 'r64') or '–'} | "
              f"{totals(warm, {'r64': 'r64'}) or '–'} |")
            p(f"| {ds} | cold, opened portable | {score(cold, 'r64') or '–'} | "
              f"{totals(cold, {'r64': 'portable'}) or '–'} |")
            p(f"| {ds} | cold, opened frozen | {score(cold, 'r64_frozen') or '–'} | "
              f"{totals(cold, {'r64_frozen': 'frozen'}) or '–'} |")
        p("")
    if synthetic:
        p("| synthetic family | typical row (vs CRoaring; portable where a format is involved) | vs frozen | total time |")
        p("|---|---|---|---|")
        fam_scores = {}
        for fam in STEPPED + MASKED:
            cells = [r for n, r in synthetic.items() if n.split("/")[0] == fam]
            sp = score(cells, "r64") or "–"
            sf = score(cells, "r64_frozen") or "–"
            impls = {"r64": "portable", "r64_frozen": "frozen"} if fam in FORMAT_FAMILIES else {"r64": "r64"}
            g = geomean([ratio(c, "r64") for c in cells])
            if g is not None:
                fam_scores[fam] = g
            p(f"| {fam} | {sp} | {sf} | {totals(cells, impls) or '–'} |")
        ops_scores = [g for f, g in fam_scores.items() if f not in FORMAT_FAMILIES]
        if ops_scores:
            p(f"| **across the operation families** (Serialize/Deserialize excluded, each family weighted equally) | **{fmt(geomean(ops_scores))}** | | |")
        if fam_scores:
            p(f"| **across all families** (each weighted equally) | **{fmt(geomean(list(fam_scores.values())))}** | | |")
        p("")

    if runs:
        p("## Data sets")
        p("")
        p("| set | bitmaps | values | zroar | r64 portable | run-container saving | r64 frozen |")
        p("|---|---|---|---|---|---|---|")
        for ds, (m, _) in runs.items():
            z, r, nr, fr = (int(m.get(k, 0)) for k in ("bytes_zroar", "bytes_r64", "bytes_r64_norun", "bytes_r64_frozen"))
            saving = f"{(1 - r / nr) * 100:.0f}%" if nr else "–"
            p(f"| {ds} | {m.get('bitmaps', m.get('files', '?'))} | {int(m.get('values', 0)):,} | {bytes_h(z)} | "
              f"{bytes_h(r)} ({r / z:.2f}× of zroar) | {saving} | {bytes_h(fr)} ({fr / z:.2f}×) |")
        p("")

        def table(names, title, note, labels):
            p(f"## {title}")
            p("")
            p(note)
            p("")
            p("| benchmark | " + " | ".join(runs) + " |")
            p("|---|" + "---|" * len(runs))
            for n in names:
                cells = [both(rows.get(n)) for _, rows in runs.values()]
                p(f"| {n} | " + " | ".join(cells) + " |")
            p("")
            wins(names, [rows for _, rows in runs.values()], labels)

        def wins(names, tables, labels):
            for impl, label in labels:
                faster = total = 0
                for rows in tables:
                    for n in names:
                        r = ratio(rows.get(n), impl)
                        if r is None:
                            continue
                        total += 1
                        faster += r > 1
                if total:
                    p(f"zroar faster than {label} on {faster} of {total} cells.")
            p("")

        table(REALDATA_ROWS, "realdata — CRoaring's bench.cpp rows, bitmaps already in memory",
              "Both libraries hold the data set's 200 bitmaps in memory (built once, "
              "before timing); each cell is CRoaring's time ÷ zroar's for that benchmark. "
              "One column per data set.",
              [("r64", "CRoaring")])
        table(COLD_ROWS, "cold — the same rows, but every bitmap is opened inside the timed call",
              "Cells read `portable / frozen`: CRoaring's time opening its bitmaps from "
              "that format and doing the work, ÷ zroar's time doing the same from its "
              "buffer.",
              [("r64", "CRoaring portable"), ("r64_frozen", "CRoaring frozen")])

    if synthetic:
        p("## synthetic — CRoaring's synthetic_bench.cpp rows, generated shapes")
        p("")
        p("- Each shape is `count` values spaced `step` apart (their `r64X/count/step`, "
          "with the step written as a power of two here).")
        p("- Step 1 packs everything into one dense container; from step 2^16 up "
          "every value sits in its own container under its own key.")
        p("- Cells are again CRoaring's time ÷ zroar's, per operation for the "
          "Contains rows and per whole build/serialize otherwise.")
        p("- At step 2^48 `count × step` overflows past 65,536 values (in C too), so "
          "those cells re-insert the same 65,536 values.")
        p("")
        if args.full:
            for fam in STEPPED:
                impls = [("r64", "portable"), ("r64_frozen", "frozen")] if fam in ("Serialize", "Deserialize") else [("r64", "")]
                for impl, label in impls:
                    p(f"**{fam}**" + (f" vs {label}" if label else ""))
                    p("")
                    p("| count \\ step | " + " | ".join(STEP_LABELS) + " |")
                    p("|---|" + "---|" * len(STEPS))
                    for c in COUNTS:
                        cells = [fmt(ratio(synthetic.get(f"{fam}/{c}/{s}"), impl)) for s in STEPS]
                        p(f"| {c:,} | " + " | ".join(cells) + " |")
                    p("")
        else:
            p("Steps 2^16 and up behave alike, so they share one column showing the "
              "range across them (`--full` prints every step). Serialize and "
              "Deserialize cells read `portable / frozen`.")
            p("")
            p("| benchmark | count | step 1 | step 2^8 | steps 2^16–2^48 |")
            p("|---|---|---|---|---|")
            for fam in STEPPED:
                for c in COUNTS:
                    def cell(steps):
                        cs = [synthetic.get(f"{fam}/{c}/{s}") for s in steps]
                        pr = fmt_range([ratio(x, "r64") for x in cs])
                        if fam in ("Serialize", "Deserialize"):
                            return f"{pr} / {fmt_range([ratio(x, 'r64_frozen') for x in cs])}"
                        return pr
                    p(f"| {fam} | {c:,} | {cell(STEPS[:1])} | {cell(STEPS[1:2])} | {cell(STEPS[2:])} |")
            p("")
        p("Random values under CRoaring's ten bitmasks: 2^20 random values "
          "inserted, then random operations on them. Every mask sets 20 bits; "
          "they differ in where. Mask 0 puts them all below bit 16 (16 "
          "containers, all the work inside them); masks 1, 2, 3, 5, 6 and 8 "
          "put none there (2^20 keys with one value each, all the work in the "
          "key index, keys added and removed at random); 4, 7 and 9 mix the "
          "two. Grouped that way, as ranges"
          + (":" if args.full else " (`--full` prints every mask):"))
        p("")
        if args.full:
            p("| benchmark \\ mask | " + " | ".join(str(i) for i in range(10)) + " |")
            p("|---|" + "---|" * 10)
            for fam in MASKED:
                p(f"| {fam} | " + " | ".join(fmt(ratio(synthetic.get(f"{fam}/{i}"), "r64")) for i in range(10)) + " |")
        else:
            p("| benchmark | containers only (mask 0) | key index only (1, 2, 3, 5, 6, 8) | mixed (4, 7, 9) |")
            p("|---|---|---|---|")
            for fam in MASKED:
                def group(masks):
                    return fmt_range([ratio(synthetic.get(f"{fam}/{i}"), "r64") for i in masks])
                p(f"| {fam} | {group([0])} | {group([1, 2, 3, 5, 6, 8])} | {group([4, 7, 9])} |")
        p("")
        for impl, label in (("r64", "CRoaring (portable where a format is involved)"), ("r64_frozen", "CRoaring frozen")):
            rs = [ratio(r, impl) for r in synthetic.values()]
            rs = [r for r in rs if r is not None]
            if rs:
                p(f"zroar faster than {label} on {sum(r > 1 for r in rs)} of {len(rs)} rows.")
        p("")

    sys.stdout.write("\n".join(out).rstrip("\n") + "\n")


if __name__ == "__main__":
    main()

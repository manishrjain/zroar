#!/usr/bin/env python3
"""Render the bench's --out files as one Markdown report.

    zig build bench -- <data_dir> --out results/census1881.tsv
    zig build bench -- --oltp --out results/oltp.tsv
    zig build bench -- --suite synthetic --out results/synthetic.tsv
    bench/report.py results/*.tsv > BENCHMARKS.md

Every cell is a ratio, CRoaring's time over zroar's, so >1 means zroar is
faster. The synthetic grid is condensed by default: the steps from 2^16 up
behave alike (one value per key), so they are shown as a range; --full prints
every cell. Absolute times stay in the .tsv files.
"""

import argparse
import datetime
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
STEPS = [1, 1 << 8, 1 << 16, 1 << 24, 1 << 32, 1 << 40, 1 << 48]
STEP_LABELS = ["1", "2^8", "2^16", "2^24", "2^32", "2^40", "2^48"]
STEPPED = ["ContainsHit", "ContainsMiss", "Insert", "Remove", "Serialize", "Deserialize"]
MASKED = ["ContainsRandom", "InsertRemoveRandom"]

PREAMBLE = """\
Every cell is CRoaring's time divided by zroar's on the same row, so **>1 means
zroar is faster**. Rows are CRoaring's own 64-bit benchmarks (`bench.cpp` on
the per-file bitmaps of each data set; `synthetic_bench.cpp` on its shape
grid), ported line for line, plus the `cold` suite: the same realdata rows with
every bitmap opened from its serialized form inside the call, and `MixedOLTP`,
a posting-list transaction (open, 90 point reads, 10 appends, close).
Where a buffer is opened or written, CRoaring has two formats and both get a
column: **portable** (the interchange format; a full parse to open) and
**frozen** (its memory layout viewed in place, read-only — the class zroar's
format belongs to). Cells read `portable / frozen`. Frozen views are read-only,
so `MixedOLTP` has no frozen column. zroar has no run containers, so data sets
where run containers shrink CRoaring's bitmaps a lot are left out of the
standard set; the saving is shown per set below.
"""


def parse(path):
    meta, rows = {}, {}
    with open(path) as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if parts[0] == "meta":
                meta[parts[1]] = parts[2]
            elif parts[0] == "row":
                _, suite, name, impl, ns = parts
                rows.setdefault(name, {"suite": suite})[impl] = float(ns)
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
    for path in args.files:
        meta, rows = parse(path)
        versions.add((meta.get("zig", "?"), meta.get("croaring", "?")))
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

    out = []
    p = out.append
    p("# zroar vs CRoaring roaring64")
    p("")
    vs = ", ".join(f"Zig {z}, CRoaring {c}" for z, c in sorted(versions))
    p(f"Generated {datetime.date.today()} by `bench/report.py` from `zig build bench --out` "
      f"files ({vs}, ReleaseFast). Ratios; absolute times are in the .tsv files.")
    p("")
    p(PREAMBLE)

    if runs:
        p("## Data sets")
        p("")
        p("| set | files | values | zroar | r64 portable | run-container saving | r64 frozen |")
        p("|---|---|---|---|---|---|---|")
        for ds, (m, _) in runs.items():
            z, r, nr, fr = (int(m.get(k, 0)) for k in ("bytes_zroar", "bytes_r64", "bytes_r64_norun", "bytes_r64_frozen"))
            saving = f"{(1 - r / nr) * 100:.0f}%" if nr else "–"
            p(f"| {ds} | {m.get('files', '?')} | {int(m.get('values', 0)):,} | {bytes_h(z)} | "
              f"{bytes_h(r)} ({r / z:.2f}× of zroar) | {saving} | {bytes_h(fr)} ({fr / z:.2f}×) |")
        p("")

        def table(names, title):
            p(f"## {title}")
            p("")
            p("| row | " + " | ".join(runs) + " |")
            p("|---|" + "---|" * len(runs))
            for n in names:
                cells = [both(rows.get(n)) for _, rows in runs.values()]
                p(f"| {n} | " + " | ".join(cells) + " |")
            p("")
            wins(names, [rows for _, rows in runs.values()])

        def wins(names, tables):
            for impl, label in (("r64", "portable"), ("r64_frozen", "frozen")):
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

        table(REALDATA_ROWS, "realdata — CRoaring bench.cpp, warm per-file bitmaps")
        table(COLD_ROWS, "cold — the same rows with the open inside the call")

    if synthetic:
        p("## synthetic — CRoaring synthetic_bench.cpp, r64 rows")
        p("")
        p("`X/count/step` is their `r64X/count/step`: `count` values `i * step`, "
          "so step 1 is one dense container and step ≥ 2^16 is one value per key. "
          "At 2^48 the product wraps past 2^64 above 65,536 values, in C as here.")
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
            p("Steps from 2^16 up behave alike, so they are one column with the "
              "range across them (`--full` prints every cell). Serialize and "
              "Deserialize read `portable / frozen`.")
            p("")
            p("| row | count | step 1 | step 2^8 | steps 2^16–2^48 |")
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
        p("Under the ten bitmasks (indexed as their DenseRange does; masks 1, 2, 3, "
          "5, 6 and 8 have no bits below bit 16, so every value is its own key):")
        p("")
        p("| row | " + " | ".join(str(i) for i in range(10)) + " |")
        p("|---|" + "---|" * 10)
        for fam in MASKED:
            p(f"| {fam} | " + " | ".join(fmt(ratio(synthetic.get(f"{fam}/{i}"), "r64")) for i in range(10)) + " |")
        p("")
        for impl, label in (("r64", "portable"), ("r64_frozen", "frozen")):
            rs = [ratio(r, impl) for r in synthetic.values()]
            rs = [r for r in rs if r is not None]
            if rs:
                p(f"zroar faster than {label} on {sum(r > 1 for r in rs)} of {len(rs)} rows.")
        p("")

    sys.stdout.write("\n".join(out).rstrip("\n") + "\n")


if __name__ == "__main__":
    main()

#!/usr/bin/env sh
# Runs the standard benchmark set and renders BENCHMARKS.md from it.
#
# Usage: bench/run_all.sh [results_dir] [extra bench args...]
#
# Data sets: the CRoaring realdata sets on which run containers buy CRoaring
# little (zroar has none, so the others would measure run containers as much
# as anything else — see the "run-container saving" column in the report),
# plus the two generated OLTP indexes; the synthetic grid once, since it does
# not depend on the data. Extra arguments go to every bench run, e.g.
# `--time 200` for a quicker, noisier pass. About 25 minutes at the default
# 500 ms per row; the synthetic grid is most of it.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
results=${1:-$here/results}
[ $# -gt 0 ] && shift
realdata=${CROARING_DIR:-/tmp/CRoaring}/benchmarks/realdata

mkdir -p "$results"
cd "$root"
for d in census1881 census-income weather_sept_85; do
    zig build bench -- "$realdata/$d" --suite realdata --suite cold --out "$results/$d.tsv" "$@"
done
zig build bench -- --oltp --suite realdata --suite cold --out "$results/oltp.tsv" "$@"
zig build bench -- --oltp-random --suite realdata --suite cold --out "$results/oltp-random.tsv" "$@"
zig build bench -- --suite synthetic --out "$results/synthetic.tsv" "$@"

python3 "$here/report.py" \
    "$results/census1881.tsv" "$results/census-income.tsv" "$results/weather_sept_85.tsv" \
    "$results/oltp.tsv" "$results/oltp-random.tsv" "$results/synthetic.tsv" > "$root/BENCHMARKS.md"
echo "wrote $root/BENCHMARKS.md from $results"

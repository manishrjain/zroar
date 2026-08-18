#!/usr/bin/env sh
# Runs benchmark data sets and renders a report from the results.
#
# Usage: bench/run_all.sh [-d set]... [-o prefix] [-c cpu] [-- bench args]
#
#   -d set     data set to run; repeat for several: -d census1881 -d oltp
#                census1881, census-income, weather_sept_85   CRoaring realdata
#                oltp                                         generated index
#                synthetic                                    the shape grid
#              Any other CRoaring realdata directory name also works.
#              Default: all five above.
#   -o prefix  output prefix (default bench/results/run); writes
#              <prefix>-<set>.tsv and <prefix>-report.md
#   -c cpu     CPU to pin the bench to (default $BENCH_CPU, else 3)
#   -- ...     passed to every bench run, e.g. -- --time 200
#
# The report is rebuilt from every <prefix>-*.tsv present, so running one
# set refreshes its column and keeps the others.
#
# Avoid data sets that lean heavily on run containers, which zroar does not
# have: wikileaks-noquotes and every _srt set (run containers shrink CRoaring's
# bitmaps there by 64-90%, versus 1-6% on the three above). The report shows
# the saving per set. uscensus2000 is tiny (30 values per file) and says
# little either way.
#
# Frequency policy is left alone: the bench records the governor, boost and
# SMT state it ran under and the report shows them, so set the machine up
# first if the numbers are meant to be kept. The full default set takes about
# 25 minutes at 500 ms per row; the synthetic grid is most of it.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
realdata=${CROARING_DIR:-/tmp/CRoaring}/benchmarks/realdata

prefix=$here/results/run
cpu=${BENCH_CPU:-3}
sets=""
while getopts "d:o:c:h" opt; do
    case $opt in
        d) sets="$sets $OPTARG" ;;
        o) prefix=$OPTARG ;;
        c) cpu=$OPTARG ;;
        *) sed -n '2,/^set -eu/{/^set -eu/!s/^# \{0,1\}//p}' "$0"; exit 2 ;;
    esac
done
shift $((OPTIND - 1))
[ -z "$sets" ] && sets="census1881 census-income weather_sept_85 oltp synthetic"
# The prefix is relative to where the script was invoked, not to the repo
# root the build runs from below.
case $prefix in /*) ;; *) prefix=$PWD/$prefix ;; esac

cd "$root"
zig build bench-exe
if command -v taskset >/dev/null 2>&1; then
    bench="taskset -c $cpu $root/zig-out/bin/bench"
else
    echo "taskset not found; running unpinned" >&2
    bench="$root/zig-out/bin/bench"
fi

mkdir -p "$(dirname "$prefix")"
for set in $sets; do
    case $set in
        synthetic)   $bench --suite synthetic --out "$prefix-synthetic.tsv" "$@" ;;
        oltp)        $bench --oltp --suite realdata --suite cold --out "$prefix-oltp.tsv" "$@" ;;
        *)           $bench "$realdata/$set" --suite realdata --suite cold --out "$prefix-$set.tsv" "$@" ;;
    esac
done

python3 "$here/report.py" "$prefix"-*.tsv > "$prefix-report.md"
echo "wrote $prefix-report.md"

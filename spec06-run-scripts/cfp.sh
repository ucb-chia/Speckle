#!/bin/bash
# On-target driver for one CFP2006 benchmark. Identical in behavior to
# cint.sh — kept as a separate file so each suite's overlay has a runner
# named after the suite (and so future suite-specific tweaks stay isolated).

# Defaults
copies=1
num_threads=1
counters=0

function usage {
    cat <<EOF
usage: cfp.sh <benchmark> [options]
  benchmark      a CFP2006 run dir under \$PWD (e.g. 410.bwaves)
  --threads N    OpenMP threads for the (single) measured process. Default 1.
  --copies  N    Run N concurrent copies (rate-style). Default 1.
  --workload N   Run only run_workload<N>.sh (else run.sh = all workloads).
                 Single-process mode only.
  --counters     Wrap with start/stop_counters (if available on target).
  -h|--help
EOF
}

if [ $# -eq 0 ] || [ "$1" = "-h" ] || [ "$1" = "-H" ] || [ "$1" = "--help" ]; then
    usage
    exit 3
fi

bmark=$1
shift

while test $# -gt 0; do
    case "$1" in
        --threads)  shift; num_threads=$1 ;;
        --copies)   shift; copies=$1 ;;
        --workload) shift; workload_num=$1 ;;
        --counters) counters=1 ;;
        -h|-H|--help) usage; exit 0 ;;
        --*) echo "ERROR: bad option $1"; usage; exit 1 ;;
        *)   echo "ERROR: bad argument $1"; usage; exit 2 ;;
    esac
    shift
done

work_dir=$PWD
mkdir -p ~/output
export OMP_NUM_THREADS=$num_threads

if [ ! -d "${work_dir}/${bmark}" ]; then
    echo "ERROR: no such benchmark: ${work_dir}/${bmark}" >&2
    exit 1
fi

if [ -z "${DISABLE_COUNTERS}" ] && [ "${counters}" -ne 0 ]; then
    start_counters
fi

if [ "${copies}" -gt 1 ]; then
    if [ -n "${workload_num}" ]; then
        echo "ERROR: --workload is incompatible with --copies > 1" >&2
        exit 1
    fi
    echo "Starting ${bmark} with ${copies} copies"
    for i in $(seq 0 $((copies - 1))); do
        cp -al "${work_dir}/${bmark}" "${work_dir}/copy-${i}"
    done
    for i in $(seq 0 $((copies - 1))); do
        ( cd "${work_dir}/copy-${i}"
          echo "name,RealTime,UserTime,KernelTime,copy" >> ~/output/${bmark}_${i}.csv
          /usr/bin/time -a -o ~/output/${bmark}_${i}.csv -f "${bmark},%e,%U,%S,${i}" \
              ./run.sh > ~/output/${bmark}_${i}.out 2> ~/output/${bmark}_${i}.err ) &
    done
    sleep 10
    while pgrep -f run.sh > /dev/null; do sleep 10; done
else
    if [ -z "${workload_num}" ]; then
        runscript="run.sh"
        full_name="${bmark}"
        echo "Starting ${bmark} with OMP_NUM_THREADS=${OMP_NUM_THREADS}"
    else
        runscript="run_workload${workload_num}.sh"
        full_name="${bmark}_${workload_num}"
        echo "Starting ${bmark} (workload ${workload_num}) with OMP_NUM_THREADS=${OMP_NUM_THREADS}"
    fi

    cd "${work_dir}/${bmark}"

    if [ -x "${work_dir}/tma_reader" ]; then
        "${work_dir}/tma_reader" > ~/output/${full_name}_tma_before.csv
    fi

    echo "name,RealTime,UserTime,KernelTime" >> ~/output/${full_name}.csv
    /usr/bin/time -a -o ~/output/${full_name}.csv -f "${full_name},%e,%U,%S" \
        ./${runscript} > ~/output/${full_name}.out 2> ~/output/${full_name}.err

    if [ -x "${work_dir}/tma_reader" ]; then
        "${work_dir}/tma_reader" > ~/output/${full_name}_tma_after.csv
    fi
fi

if [ -z "${DISABLE_COUNTERS}" ] && [ "${counters}" -ne 0 ]; then
    stop_counters
fi

echo "Spec run finished"

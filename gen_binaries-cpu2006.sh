#!/bin/bash
# SPEC CPU2006 binary generator. Sibling of speckle's existing SPEC2017
# gen_binaries.sh; both live in this speckle clone, both follow the same
# pattern (find target binary in exe/ -> copy to overlay -> emit run.sh
# from commands/<bench>.<size>.cmd) -- they differ only where SPEC's two
# build harnesses do (CPU2006 uses `runspec` and benchspec/CPU2006/<bench>/
# run/run_base_<size>_<label>.0000; CPU2017 uses `runcpu` and
# benchspec/CPU/<bench>/run/run_base_<size><class>_<label>-m64.0000).
#
# Reads SPEC2006 .cmd files from commands/<bench>.<size>.cmd (flat; SPEC06
# has no speed/rate split, so the suite (cint2006 / cfp2006) is determined
# here by hard-coded benchmark lists matching SPEC's runspec partitioning).
#
# Output overlay: $script_dir/build/overlay/<suite>/<input>/<bench>/

set -e

# riscv-cpu2006.cfg sets `ext = riscv`, host-cpu2006.cfg sets `ext = host`
# -- those `ext` values become the <label> in run_base_<size>_<label>.0000.
CONFIG=riscv
CONFIGFILE=${CONFIG}-cpu2006.cfg
H_CONFIG=host
H_CONFIGFILE=${H_CONFIG}-cpu2006.cfg

# This script lives at the top level of speckle (alongside spec17's
# gen_binaries.sh, riscv.cfg, host.cfg). All SPEC06 resources -- configs,
# cmd files, on-target run scripts, tma_reader -- live in the same dir.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Mirror spec17 layout: build artifacts under $script_dir/build/.
build_dir="${script_dir}/build"
overlay_dir="${build_dir}/overlay"

# stdout redirection in the on-target run.sh — set true to keep `> *.out`
# tails from the .cmd files. Default false: simulator harnesses like to
# capture stdout/stderr via /usr/bin/time wrappers, not via per-cmd files.
REDIRECT=false

compileFlag=false
genCommandsFlag=false
suite_type=cint2006
input_type=ref

function usage {
    cat <<EOF
usage: gen_binaries-cpu2006.sh [--compile | --genCommands] [--suite <cint2006|cfp2006>] [--input <test|train|ref>]
    --compile         build target binaries via runspec, populate overlay
    --genCommands     re-derive .cmd files from a fake runspec invocation
                      (only useful when you have a SPEC06 install and want
                      to refresh commands/<bench>.<size>.cmd)
    --suite           cint2006 (12 INT) or cfp2006 (17 FP). Default: cint2006.
    --input           test, train, or ref. All three sizes ship cmd files
                      in commands/<bench>.<size>.cmd at the top level.
EOF
}

while test $# -gt 0; do
   case "$1" in
        --compile)        compileFlag=true ;;
        --genCommands)    genCommandsFlag=true ;;
        --suite)          shift; suite_type=$1 ;;
        --input)          shift; input_type=$1 ;;
        -h|-H|--help)     usage; exit 0 ;;
        --*)  echo "ERROR: bad option $1"; usage; exit 1 ;;
        *)    echo "ERROR: bad argument $1"; usage; exit 2 ;;
    esac
    shift
done

case "$suite_type" in
    cint2006|cfp2006) ;;
    *) echo "ERROR: --suite must be cint2006 or cfp2006 (got: $suite_type)"; exit 1 ;;
esac

case "$input_type" in
    test|ref|train) ;;
    *) echo "ERROR: --input must be test, train, or ref (got: $input_type)"; exit 1 ;;
esac

# Anything that actually invokes runspec needs $SPEC_DIR; argument-only
# invocations (e.g. --help) don't.
if { [ "$compileFlag" = true ] || [ "$genCommandsFlag" = true ]; } && [ -z "$SPEC_DIR" ]; then
   echo "  Please set SPEC_DIR to point to your SPEC CPU2006 v1.2 installation."
   exit 1
fi

# CINT2006 (12) and CFP2006 (17) benchmark partitions. Authoritative per
# https://www.spec.org/cpu2006/Docs/runspec.html.
cint2006_benchmarks=(
    400.perlbench 401.bzip2 403.gcc 429.mcf 445.gobmk 456.hmmer
    458.sjeng 462.libquantum 464.h264ref 471.omnetpp 473.astar 483.xalancbmk
)
cfp2006_benchmarks=(
    410.bwaves 416.gamess 433.milc 434.zeusmp 435.gromacs 436.cactusADM
    437.leslie3d 444.namd 447.dealII 450.soplex 453.povray 454.calculix
    459.GemsFDTD 465.tonto 470.lbm 481.wrf 482.sphinx3
)

if [ "$suite_type" = "cint2006" ]; then
    benchmarks=("${cint2006_benchmarks[@]}")
    runspec_suite=int   # what `runspec --action build int` expects
else
    benchmarks=("${cfp2006_benchmarks[@]}")
    runspec_suite=fp
fi

echo "== gen_binaries.sh (SPEC CPU2006) =="
echo "  Config : ${CONFIG}"
echo "  Suite  : ${suite_type} (${#benchmarks[@]} benchmarks)"
echo "  Input  : ${input_type}"
echo "  compile: ${compileFlag}"
echo "  genCmd : ${genCommandsFlag}"
echo ""

mkdir -p "${build_dir}"

if [ "$compileFlag" = true ]; then
    # riscv-cpu2006.cfg references %{ENV_TMA_INJECT_OBJ} in EXTRA_LIBS, so
    # runspec must see TMA_INJECT_OBJ in its environment. The Makefile
    # passes it in; export it explicitly so shell sourcing of $SPEC_DIR/shrc
    # doesn't drop it on the floor. SPEC2006 has no speed/rate split, so
    # every suite needs the injection (unlike spec17 where intrate is
    # excluded).
    if [ -z "$TMA_INJECT_OBJ" ]; then
        echo "ERROR: TMA_INJECT_OBJ env var not set (build via 'make spec06-${suite_type}')" >&2
        exit 1
    fi
    if [ ! -f "$TMA_INJECT_OBJ" ]; then
        echo "ERROR: TMA_INJECT_OBJ=$TMA_INJECT_OBJ does not exist" >&2
        exit 1
    fi
    export TMA_INJECT_OBJ

    echo "Compiling SPEC CPU2006..."
    # SPEC2006's runspec lacks the %{ENV_FOO} build-time substitution that
    # runcpu has in SPEC2017 (CPU2006 only supports preENV_*/ENV_* runtime
    # injection). The cfg ships with `EXTRA_LIBS = %{ENV_TMA_INJECT_OBJ}`
    # as a template placeholder; resolve it ourselves with sed before
    # handing the cfg to runspec, so SPEC's link line gets the real path.
    sed "s|%{ENV_TMA_INJECT_OBJ}|${TMA_INJECT_OBJ}|g" "${script_dir}/${CONFIGFILE}"   > "${SPEC_DIR}/config/${CONFIGFILE}"
    sed "s|%{ENV_TMA_INJECT_OBJ}|${TMA_INJECT_OBJ}|g" "${script_dir}/${H_CONFIGFILE}" > "${SPEC_DIR}/config/${H_CONFIGFILE}"

    # `runspec --config NAME` resolves NAME against $SPEC_DIR/config/NAME.cfg.
    # We pass the basename of CONFIGFILE (riscv-cpu2006), not CONFIG (riscv),
    # because $SPEC_DIR/config/riscv.cfg is the SPEC2017 cfg co-installed by
    # the spec17 build path. Same for H_CONFIG/H_CONFIGFILE.
    echo "Building target binaries with config: ${CONFIGFILE}"
    ( cd "${SPEC_DIR}" && . ./shrc && \
      time runspec --verbose 10 --config "${CONFIGFILE%.cfg}" --size ${input_type} \
                   --action build ${runspec_suite} \
        > "${build_dir}/${CONFIG}-${suite_type}-build.log" )

    echo "Compiling host binaries + materializing inputs with config: ${H_CONFIGFILE}"
    ( cd "${SPEC_DIR}" && . ./shrc && \
      time runspec --verbose 10 --config "${H_CONFIGFILE%.cfg}" --size ${input_type} \
                   --action runsetup ${runspec_suite} \
        > "${build_dir}/${H_CONFIG}-${suite_type}-build.log" )

    for b in "${benchmarks[@]}"; do
        output_dir="${overlay_dir}/${suite_type}/${input_type}/${b}"
        mkdir -p "${output_dir}"

        bmark_base_dir="${SPEC_DIR}/benchspec/CPU2006/${b}"
        # SPEC06 run-dir layout has no class/-m64; only <size>_<label>.0000
        host_bmk_dir="${bmark_base_dir}/run/run_base_${input_type}_${H_CONFIG}.0000"

        # Copy all input files + directories EXCEPT the SPEC-built host
        # binary (which has the *_base.<H_CONFIG>* suffix). Filtering on
        # `! -executable` is wrong: some SPEC inputs (e.g. perlbench train's
        # .pl scripts) ship with execute bits set and would be silently
        # dropped, leaving the on-target run.sh referencing missing files.
        inputs=$(find "${host_bmk_dir}"/* -maxdepth 0 ! -name "*_base.${H_CONFIG}*")
        for input in ${inputs}; do
            cp -rf "${input}" -T "${output_dir}/$(basename "${input}")"
        done

        # SPEC's exe/ contains exactly one *_base.<CONFIG>* per benchmark.
        # SPEC names it after the upstream project's executable name (e.g.
        # 483.xalancbmk -> Xalan_base.<ext>, 482.sphinx3 ->
        # sphinx_livepretend_base.<ext>). We don't care: take the binary
        # as-is and copy it into the overlay with a uniform name --
        # <short>_base.<CONFIG> -- so every bench's run.sh and overlay
        # layout look identical, no per-bench branches anywhere.
        b_short_name="${b#*.}"
        target_bin=$(find "${bmark_base_dir}/exe/" -maxdepth 1 -type f \
                          -name "*_base.${CONFIG}*" | head -1)
        if [ -z "${target_bin}" ]; then
            echo "ERROR: no *_base.${CONFIG}* binary in ${bmark_base_dir}/exe/" \
                 "(did the runspec build succeed?)"
            exit 1
        fi
        cp -f "${target_bin}" "${output_dir}/${b_short_name}_base.${CONFIG}"

        # Generate run.sh + per-workload run scripts from the .cmd file.
        cmd_file="${script_dir}/commands/${b}.${input_type}.cmd"
        if [ ! -f "${cmd_file}" ]; then
            echo "ERROR: no cmd file for ${b} (size=${input_type}): ${cmd_file}"
            exit 1
        fi
        run_script="${output_dir}/run.sh"
        echo "#!/bin/bash" > "${run_script}"
        echo "# Generated by speckle/gen_binaries-cpu2006.sh" >> "${run_script}"

        IFS=$'\n' read -d '' -r -a commands < "${cmd_file}" || [ "${commands[0]}" ]
        workload_idx=0
        for input in "${commands[@]}"; do
            if [[ "${input:0:1}" == '#' ]]; then continue; fi
            if [ "${REDIRECT}" = false ]; then
                input="${input% > *}"
            fi
            workload_run_script="${output_dir}/run_workload${workload_idx}.sh"
            echo "#!/bin/bash" > "${workload_run_script}"
            message="echo 'Running: ./${b_short_name}_base.${CONFIG} ${input}'"
            cmd="./${b_short_name}_base.${CONFIG} ${input}"
            echo "${message}" >> "${run_script}"
            echo "${message}" >> "${workload_run_script}"
            echo "${cmd}"     >> "${run_script}"
            echo "${cmd}"     >> "${workload_run_script}"
            chmod +x "${workload_run_script}"
            workload_idx=$((workload_idx + 1))
        done
        chmod +x "${run_script}"
    done

    # Drop the suite's master on-target runner into the overlay root.
    if [ "$suite_type" = "cint2006" ]; then
        cp "${script_dir}/spec06-run-scripts/cint.sh" "${overlay_dir}/${suite_type}/${input_type}/"
    else
        cp "${script_dir}/spec06-run-scripts/cfp.sh"  "${overlay_dir}/${suite_type}/${input_type}/"
    fi

    # Optional: drop in the cross-compiled tma_reader if Makefile built it.
    if [ -f "${script_dir}/tma_reader" ]; then
        cp "${script_dir}/tma_reader" "${overlay_dir}/${suite_type}/${input_type}/tma_reader"
        chmod +x "${overlay_dir}/${suite_type}/${input_type}/tma_reader"
    fi
fi

# (Re)derive cmd files from a fake runspec — only useful when you have a
# SPEC06 install and want to refresh commands/. Mirrors the spec17 helper.
if [ "$genCommandsFlag" = true ]; then
    log_file="${build_dir}/${suite_type}.${input_type}.fakerun.log"
    ( cd "${SPEC_DIR}" && . ./shrc && \
      time runspec --config="${H_CONFIGFILE%.cfg}" --fake --verbose 9 --size ${input_type} \
                   --action=onlyrun ${runspec_suite} > "${log_file}" )

    bmarks=($(grep -nE "Running 4[0-9][0-9]" "${log_file}" | grep -Eo '[0-9]+\.[0-9a-zA-Z_]+'))
    out_dir="${script_dir}/commands/${suite_type}"
    mkdir -p "${out_dir}"
    for bmark in "${bmarks[@]}"; do
        start_line=$(grep -nE "Running ${bmark}" "${log_file}" | grep -Eo '^[0-9]+')
        end_line=$(grep -nE "Run ${bmark}"     "${log_file}" | grep -Eo '^[0-9]+')
        sed "${start_line},${end_line}!d" "${log_file}" \
            | grep '^\.\./run_base' \
            | sed 's/[^ ]* //' \
            > "${out_dir}/${bmark}.${input_type}.cmd"
    done
fi

echo ""
echo "Done!"

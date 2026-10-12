#!/bin/bash
# =============================================================================
# run_sspi_tb.sh - SSPI RTL testbench launcher
#
# RTL-level test suite modelled on 
# gc2025/hw/sim_scripts/run_sim.sh
# trisoc/sim_scripts/run_sim.sh
# These are script files used to perform the full simulation flow on a built 
# simulation executable from running 'make build_sim' on these directories.
# Script drives the SSPI(s) modelled on a set of C testcase on the SoC core;
# provides waveform and internal-trace access the C level cannot reach.
#
# DEFAULTS reproduce GCSDK/software/examples/sspi_testcases/
# sspi_simplex_tx/sspi_simplex_tx.c exactly, so a bare run executes that
# testcase. Every flag maps to a driver call or constant in bsp/include/sspi.h.
#
# bsc has no $value$plusargs, so numeric config is compile-time: each run
# recompiles the testbench (~15s).
#
# Examples:
#   ./run_sspi_tb.sh                                  # sspi_simplex_tx.c defaults
#   ./run_sspi_tb.sh --rtl sspi_first_edge.bsv        # rtl/sspi_first_edge.bsv
#   ./run_sspi_tb.sh --tb sspi_fullduplex_tb.bsv      # testbenches/sspi_fullduplex_tb.bsv
#   ./run_sspi_tb.sh --data 0xAA,0x55,0xF0,0x0F       # explicit bytes
#   ./run_sspi_tb.sh --nbytes 16 --seed 0x10 --incr 2
#   ./run_sspi_tb.sh --cpha 1 --save --name cpha1
#   ./run_sspi_tb.sh --sweep
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/sim_results"
DATA_FILE="$SCRIPT_DIR/sspi_tb_data.bsvi"   # included by the testbench; stays in the root

# Defaults: sspi_simplex_tx.c - this simplex mode was the central issue at first.
NBYTES=8; DATA_SIZE=8; CPOL=0; CPHA=0; LSB=0
SETUP=1; HOLD=0; BITRATE=100000; PRESCALE=""; SEED=1; INCR=1
GAP=4; WAIT=""; DATA_LIST=""
NAME=""; DO_SAVE=0; FORCE=0; DO_CLEAN=0; VERBOSE=0; DO_SWEEP=0; VCD=0

# Sources under test. ACTIVE_RTL is the filename the testbench imports as
# `package sspi`; --rtl copies a variant over it. TB is the top BSV file.
RTL_DIR="rtl"              # RTL versions live here
TB_DIR="testbenches"       # testbench versions live here
ACTIVE_RTL="$RTL_DIR/sspi.bsv"
RTL_SRC=""
TB="$TB_DIR/sspi_simplex_tb.bsv"

CLOCK_FREQUENCY=50000000        # platform.h

usage() {
cat <<EOF

Usage: $0 [OPTIONS]

Defaults reproduce GCSDK sspi_simplex_tx.c. Run with no arguments for that testcase if you wish.

Sources under test:
  --rtl <file>       RTL version to test, from $RTL_DIR/ (a bare name is
                     resolved there). Must declare 'package sspi;'. It is copied
                     over $ACTIVE_RTL, the only filename bsc resolves
                     'import sspi' to; the file it replaces is kept as
                     $ACTIVE_RTL.prev. Variants sitting in $RTL_DIR/ under any
                     other name are inert until made active this way.
  --tb <file>        Testbench to build, from $TB_DIR/ (a bare name is resolved
                     there). Its package name must match its filename and its
                     top module must be mkTest.
                     (default $TB)

Transfer configuration (each maps to a driver call in sspi_driver.c):
  --nbytes <1-31>    SSPI_SIZE, bytes per transfer                 (default $NBYTES)
  --data-size <n>    DATA_SIZE, bits per byte                      (default $DATA_SIZE)
  --cpol <0|1>       CLK_POLARITY_LOW / _HIGH                      (default $CPOL)
  --cpha <0|1>       CLK_PHASE_LOW / _HIGH                         (default $CPHA)
  --lsb-first        LSB_FIRST instead of MSB_FIRST
  --setup <n>        SETUP_TIME_CYCLES -> cs_t_delay               (default $SETUP)
  --hold <n>         HOLD_TIME_CYCLES  -> t_cs_delay               (default $HOLD)
  --bitrate <hz>     SSPI_CLOCK_FREQUENCY; prescale computed as
                     sspi_configure_clock_in_hz() does, including
                     its uint8_t truncation                        (default $BITRATE)
  --prescale <n>     Raw prescaler, bypassing --bitrate

Data (byte by byte, as the testcase fills spi2_tx[]):
  --data <list>      Explicit bytes, e.g. 0xAA,0x55,0xF0 - also sets --nbytes
  --seed <hex>       First byte  (temp_data)                       (default 0x01)
  --incr <hex>       Increment per byte                            (default 0x01)

Run control:
  --gap <n>          Idle cycles between register accesses         (default $GAP)
  --wait <n>         Override the derived settle time, in cycles
  --name <tag>       Tag for the saved log
  --save             Save to sim_results/<name>/ : run.log + dump.vcd +
                     config.txt, on failure as well as success
  --force            Overwrite an existing sim_results/<name>/ directory
  --clean            make full_clean before building
  --vcd              Generate dump.vcd for waveform viewing
  --verbose          Show the DUT internal trace (+msspi +l0) and bsc output
  --sweep            Run the cpol x cpha x bit-order matrix and summarise
  -h, --help         This message

EOF
}

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --rtl)        RTL_SRC="$2";   shift ;;
        --tb)         TB="$2";        shift ;;
        --nbytes)     NBYTES="$2";    shift ;;
        --data-size)  DATA_SIZE="$2"; shift ;;
        --cpol)       CPOL="$2";      shift ;;
        --cpha)       CPHA="$2";      shift ;;
        --lsb-first)  LSB=1 ;;
        --setup)      SETUP="$2";     shift ;;
        --hold)       HOLD="$2";      shift ;;
        --bitrate)    BITRATE="$2";   shift ;;
        --prescale)   PRESCALE="$2";  shift ;;
        --data)       DATA_LIST="$2"; shift ;;
        --seed)       SEED=$(($2));   shift ;;
        --incr)       INCR=$(($2));   shift ;;
        --gap)        GAP="$2";       shift ;;
        --wait)       WAIT="$2";      shift ;;
        --name)       NAME="$2";      shift ;;
        --save)       DO_SAVE=1 ;;
        --force)      FORCE=1 ;;
        --clean)      DO_CLEAN=1 ;;
        --vcd)        VCD=1 ;;
        --verbose)    VERBOSE=1 ;;
        --sweep)      DO_SWEEP=1 ;;
        -h|--help)    usage; exit 0 ;;
        *) echo "[FAIL] Unknown argument: $1"; echo "       Run with -h for usage."; exit 1 ;;
    esac
    shift
done

cd "$SCRIPT_DIR" || exit 1

# Resolve the testbench 
# bsc requires the package name to match the filename, and the Makefile builds
# -g mkTest, so a testbench variant must declare 'package <its basename>;' and
# define module mkTest.
# A bare name is resolved inside $TB_DIR, so --tb foo_tb.bsv and
# --tb testbenches/foo_tb.bsv both work.
[[ "$TB" != */* && -f "$TB_DIR/$TB" ]] && TB="$TB_DIR/$TB"
[[ ! -f "$TB" ]] && { echo "[FAIL] --tb file not found: $TB (looked in $TB_DIR/ too)"; exit 1; }
TB_BASE="$(basename "$TB" .bsv)"     # package name and .bo stem
TB_TAG="$TB_BASE"                    # used for saved-log names
if ! grep -qE "^[[:space:]]*package[[:space:]]+${TB_BASE}[[:space:]]*;" "$TB"; then
    echo "[FAIL] $TB must declare 'package ${TB_BASE};' (bsc ties package name to filename)"
    exit 1
fi
if ! grep -qE "module[[:space:]]+mkTest[[:space:]]*\(" "$TB"; then
    echo "[FAIL] $TB must define 'module mkTest' (the Makefile builds -g mkTest)"
    exit 1
fi

# Resolve the RTL under test
# The testbench does `import sspi::*`, so bsc only ever reads ./sspi.bsv.
# Variants therefore have to be swapped into that name. Each variant still
# declares 'package sspi;', which is why it is inert until made active.
if [[ -n "$RTL_SRC" ]]; then
    [[ "$RTL_SRC" != */* && -f "$RTL_DIR/$RTL_SRC" ]] && RTL_SRC="$RTL_DIR/$RTL_SRC"
    [[ ! -f "$RTL_SRC" ]] && { echo "[FAIL] --rtl file not found: $RTL_SRC (looked in $RTL_DIR/ too)"; exit 1; }
    if ! grep -qE "^[[:space:]]*package[[:space:]]+sspi[[:space:]]*;" "$RTL_SRC"; then
        echo "[FAIL] $RTL_SRC must declare 'package sspi;' to stand in for $ACTIVE_RTL"
        exit 1
    fi
    if [[ "$(readlink -f "$RTL_SRC")" == "$(readlink -f "$ACTIVE_RTL")" ]]; then
        echo "[INFO] RTL: $ACTIVE_RTL already active"
    elif cmp -s "$RTL_SRC" "$ACTIVE_RTL"; then
        echo "[INFO] RTL: $RTL_SRC is identical to $ACTIVE_RTL, nothing to swap"
    else
        # Never silently discard the file being replaced.
        [[ -f "$ACTIVE_RTL" ]] && cp "$ACTIVE_RTL" "${ACTIVE_RTL}.prev"
        cp "$RTL_SRC" "$ACTIVE_RTL"
        echo "[INFO] RTL: $RTL_SRC -> $ACTIVE_RTL  (previous kept as ${ACTIVE_RTL}.prev)"
        # cp refreshes the mtime so bsc would rebuild anyway, but be explicit:
        # a stale sspi.bo would silently keep the old RTL elaborated in.
        rm -f build_bsim/sspi.bo   # stem is the package name, not the path
    fi
fi
[[ ! -f "$ACTIVE_RTL" ]] && { echo "[FAIL] $ACTIVE_RTL not found; pass --rtl <file>"; exit 1; }
RTL_MD5="$(md5sum "$ACTIVE_RTL" | cut -c1-8)"
# Label the variant that was swapped in, not the active filename, so the
# reproduce line in config.txt names something that reselects the same RTL.
RTL_LABEL="$(basename "${RTL_SRC:-$ACTIVE_RTL}")"
echo "[INFO] rtl=$ACTIVE_RTL (md5 $RTL_MD5)  tb=$TB"

# Prescaler, exactly as sspi_configure_clock_in_hz() computes it
# uint8_t prescaler = (CLOCK_FREQUENCY / bit_rate) - 1;
# The uint8_t truncation is reproduced deliberately: at the testcase's 100kHz
# the true value is 499, which the driver stores as 243. PLEASE NOTE
if [[ -z "$PRESCALE" ]]; then
    raw=$(( CLOCK_FREQUENCY / BITRATE - 1 ))
    PRESCALE=$(( raw & 0xFF ))
    [[ $raw -gt 255 ]] && echo "[INFO] bitrate ${BITRATE}Hz -> prescaler $raw, truncated to $PRESCALE by the driver's uint8_t"
fi

# Byte data
DATA_DEF=""
if [[ -n "$DATA_LIST" ]]; then
    IFS=',' read -ra BYTES <<< "$DATA_LIST"
    NBYTES=${#BYTES[@]}
    {
        echo "// Auto-generated by run_sspi_tb.sh - do not edit."
        echo "// Regenerate with: $0 --data $DATA_LIST"
        echo "function Vector#(MaxBytes, Bit#(8)) fn_tb_tx_data();"
        echo "  Vector#(MaxBytes, Bit#(8)) d = replicate(0);"
        for i in "${!BYTES[@]}"; do
            v=$(( ${BYTES[$i]} ))
            printf "  d[%d] = 8'h%02X;\n" "$i" "$((v & 0xFF))"
        done
        echo "  return d;"
        echo "endfunction"
    } > "$DATA_FILE"
    DATA_DEF="-D TB_DATA_FILE"
    echo "[INFO] $NBYTES bytes -> $(basename "$DATA_FILE")"
fi

if [[ $NBYTES -lt 1 || $NBYTES -gt 31 ]]; then
    echo "[FAIL] --nbytes must be 1..31 (total_bit_tx/rx are 8-bit fields)"; exit 1
fi

# One build + run; shows PASS/FAIL/ERROR at the end
run_one() {
    local cpol=$1 cpha=$2 lsb=$3 tag=$4

    local defs="-D TB_NBYTES=$NBYTES -D TB_DATA_SIZE=$DATA_SIZE"
    defs+=" -D TB_CPOL=$cpol -D TB_CPHA=$cpha -D TB_LSB_FIRST=$lsb"
    defs+=" -D TB_SETUP=$SETUP -D TB_HOLD=$HOLD -D TB_PRESCALE=$PRESCALE"
    defs+=" -D TB_SEED=$SEED -D TB_INCR=$INCR -D TB_GAP=$GAP"
    [[ -n "$WAIT"     ]] && defs+=" -D TB_WAIT=$WAIT"
    [[ -n "$DATA_DEF" ]] && defs+=" $DATA_DEF"

    local logfile; logfile="$(mktemp)"

    # bsc's dependency check only looks at source timestamps, not -D flags, so
    # without this a config change silently reuses the previous elaboration.
    rm -f "build_bsim/${TB_BASE}.bo" build_bsim/mkTest.ba

    if [[ $VERBOSE -eq 1 ]]; then
        make TOPFILE="$TB" TB_DEFINES="$defs" compile && make TOPFILE="$TB" link || { echo "ERROR"; return; }
    else
        make TOPFILE="$TB" TB_DEFINES="$defs" compile >"$logfile" 2>&1 && make TOPFILE="$TB" link >>"$logfile" 2>&1 || {
            echo "--- build failed ---"; grep -E "^Error" "$logfile" | head -5; echo "ERROR"; return; }
    fi

    local args=()
    # Saving always produces a waveform, so a saved run is always debuggable.
    [[ $VCD -eq 1 || $DO_SAVE -eq 1 ]] && args+=("-V")
    [[ $VERBOSE -eq 1 ]] && args+=("+msspi" "+l0")

    ./mkTest_bsim "${args[@]}" >"$logfile" 2>&1

    # R0002 lines are pre-existing conflict-free violations inside sspi.bsv,
    # these display whenever we perform sspi pin wiring in TbSoc.bsv
    # and we run ./out. Unavoidable as a consequence of the connections.
    # they are filtered out of the readable log.
    local clean; clean="$(mktemp)"
    grep -vE "R0002|module instance|conflicting methods|Conflict-free|^Error: \"sspi" "$logfile" \
        | grep -vE "^\s*$" > "$clean"
    cat "$clean"

    local verdict
    if   grep -q "TEST PASSED" "$clean"; then verdict="PASS"
    elif grep -q "TEST FAILED" "$clean"; then verdict="FAIL"
    else verdict="ERROR"; fi

    # Save on PASS, FAIL and ERROR alike. A failing run is the one you most
    # need the log and the waveform for. One directory per run name, holding
    # run.log, dump.vcd and the exact command needed to reproduce it.
    if [[ $DO_SAVE -eq 1 ]]; then
        local out="$RESULTS_DIR/${tag}"
        if [[ -d "$out" && $FORCE -eq 0 ]]; then
            echo "[WARN] Exists, not overwriting (use --force): sim_results/${tag}/"
        else
            rm -rf "$out"; mkdir -p "$out"
            cp "$clean" "$out/run.log"; chmod 644 "$out/run.log"
            if [[ -f dump.vcd ]]; then
                mv dump.vcd "$out/dump.vcd"
                echo "[INFO] Saved: sim_results/${tag}/{run.log,dump.vcd,config.txt}  [$verdict]"
            else
                echo "[WARN] no dump.vcd produced"
                echo "[INFO] Saved: sim_results/${tag}/{run.log,config.txt}  [$verdict]"
            fi
            {
                echo "verdict   : $verdict"
                echo "date      : $(date '+%Y-%m-%d %H:%M:%S')"
                echo "rtl       : $ACTIVE_RTL (md5 $RTL_MD5)"
                echo "testbench : $TB"
                echo "cpol      : $cpol"
                echo "cpha      : $cpha"
                echo "lsb_first : $lsb"
                echo "nbytes    : $NBYTES"
                echo "data_size : $DATA_SIZE"
                echo "prescale  : $PRESCALE"
                echo "setup     : $SETUP"
                echo "hold      : $HOLD"
                echo "seed/incr : $SEED / $INCR"
                echo "gap       : $GAP"
                echo "bsc flags : $defs"
                echo ""
                echo "reproduce :"
                echo "  ./run_sspi_tb.sh --rtl $RTL_LABEL --tb $(basename "$TB") \\"
                echo "      --cpol $cpol --cpha $cpha $([[ $lsb -eq 1 ]] && echo '--lsb-first ')\\"
                echo "      --nbytes $NBYTES --prescale $PRESCALE --setup $SETUP --hold $HOLD \\"
                echo "      --name $tag --save --force"
            } > "$out/config.txt"
        fi
    fi

    echo "$verdict"
    rm -f "$logfile" "$clean"
}

[[ $DO_CLEAN -eq 1 ]] && { echo "[INFO] make full_clean"; make full_clean >/dev/null 2>&1; }

# Sweep flag to have all combinations of CPOl, CHA, bit order tested for the same testbench
if [[ $DO_SWEEP -eq 1 ]]; then
    echo "[INFO] Sweeping cpol x cpha x bit-order; tb=$TB rtl=$ACTIVE_RTL nbytes=$NBYTES prescale=$PRESCALE"
    declare -a RESULTS
    for cpol in 0 1; do for cpha in 0 1; do for lsb in 0 1; do
        pol=$([[ $cpol -eq 0 ]] && echo lcpol || echo hcpol)
        pha=$([[ $cpha -eq 0 ]] && echo lcpha || echo hcpha)
        ord=$([[ $lsb  -eq 0 ]] && echo msb   || echo lsb)
        tag="${TB_TAG}_${pol}_${pha}_${ord}"
        printf "  %-44s " "$tag"
        v=$(run_one "$cpol" "$cpha" "$lsb" "$tag" 2>/dev/null | tail -1)
        printf "%s\n" "$v"
        RESULTS+=("$tag $v")
    done; done; done
    echo ""
    echo "──────────────────── sweep summary ────────────────────"
    printf "%s\n" "${RESULTS[@]}" | while read -r t v; do printf " %-44s %s\n" "$t" "$v"; done
    echo "───────────────────────────────────────────────────────"
    exit 0
fi

# Single run
if [[ -z "$NAME" ]]; then
    pol=$([[ $CPOL -eq 0 ]] && echo lcpol || echo hcpol)
    pha=$([[ $CPHA -eq 0 ]] && echo lcpha || echo hcpha)
    NAME="${TB_TAG}_${pol}_${pha}_${NBYTES}B"
fi

# NOTE: do not pipe through `tee /dev/stderr` here. When this script's stderr
# is a regular file (e.g. ./run_sspi_tb.sh ... > combined.log 2>&1), tee
# REOPENS and TRUNCATES that file on every invocation, so a combined log of
# several runs ends up empty. Capture once, then echo.
run_output="$(run_one "$CPOL" "$CPHA" "$LSB" "$NAME")"
printf '%s\n' "$run_output"
verdict="$(printf '%s\n' "$run_output" | tail -1)"

echo "────────────────────────────────────────────"
printf " RTL      : %s  (md5 %s)\n" "$ACTIVE_RTL" "$RTL_MD5"
printf " Testbench: %s\n" "$TB"
printf " Config   : cpol=%s cpha=%s %s nbytes=%s prescale=%s setup=%s hold=%s\n" \
       "$CPOL" "$CPHA" "$([[ $LSB -eq 1 ]] && echo LSB || echo MSB)" \
       "$NBYTES" "$PRESCALE" "$SETUP" "$HOLD"
printf " Name     : %s\n" "$NAME"
printf " Result   : %s\n" "$verdict"
echo "────────────────────────────────────────────"
[[ "$verdict" == "PASS" ]] && exit 0 || exit 1

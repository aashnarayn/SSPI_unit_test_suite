# SSPI RTL test setup

An RTL level testbench for the Shakti SSPI peripheral, built in Bluespec and run
under Bluesim. It drives `mk_sspi` directly through its `Ifc_sspi` interface, so
there is no core, fabric, pinmux or software image that causes a lot of delay and wait
in the simulation setup in both gc2025 and trisoc

## Why it exists

The GCSDK testcases in `application_examples/` exercise SSPI from C on hardware\
This setup reproduces the same register sequences at RTL level, so you get
waveforms and internal rule traces for the same stimulus. Saves a lot of time to get 
simpler and faster waveform and trace level access.

Everything here is modelled on five GCSDK testcases:

| testcase | what it does | covered by |
| --- | --- | --- |
| `sspi_simplex_tx.c` | two instances, master TX to slave RX, cpol 0 cpha 0 | `sspi_simplex_tb.bsv` |
| `sspi_simplex_rx.c` | same topology, just use one of this or the above | defaults changed `--cpol 1 --cpha 1` |
| `sspi_full_duplex.c` | one instance, MOSI shorted to MISO | `sspi_loopback_tb.bsv` |
| `sspi_MSB_check.c` | identical register sequence to the above, slightly redundant | same |
| `sspi_LSB_check.c` | same but data is transferred LSB first | same TB with `--lsb-first` |

`sspi_full_duplex.c` and `sspi_MSB_check.c` issue the same writes, so running
both adds no coverage. Three distinct applications, not five.

The defaults reproduce `sspi_simplex_tx.c` exactly: 8 bytes of 8 bits, cpol 0,
cpha 0, MSB first, setup 1, hold 0, prescale 243, payload `01 02 ... 08`. The
prescale value is what `sspi_configure_clock_in_hz()` actually produces,
including its `uint8_t` truncation of 499.

## Layout

```
rtl/                   RTL versions. sspi.bsv is the active one. This active .bsv file is overwritten when each  test is performed.
rtl/dependencies/      AXI4, ConcatReg, MIMO, Logger and friends
testbenches/           testbench versions
testbenches/sspi_tb_config.bsvi   shared defines and register packing helpers
application_examples/  the five GCSDK C testcases, for reference
run_sspi_tb.sh         the thing you actually run
Makefile               bsc compile, link and simulate
bash_commands_payload.txt   the full sweep
sim_results/           output
```

`rtl/sspi.bsv` is not in the repo, since it is regenerated on every run. Build
artifacts and `.vcd` dumps are gitignored too, so the waveforms are not shipped.
Each saved run keeps its `config.txt` with a `reproduce` line, which is enough
to regenerate any waveform you need.

## How it fits together

`run_sspi_tb.sh` is a wrapper around the Makefile. It does three things the
Makefile cannot:

1. **Swaps the RTL.** `bsc` resolves `import sspi` only to a file named
   `sspi.bsv`, so `--rtl sspi_setup_rx.bsv` copies that file over
   `rtl/sspi.bsv` and keeps the old one as `rtl/sspi.bsv.prev`. Variants sitting
   in `rtl/` under any other name are inert until activated this way.
2. **Turns flags into `-D` defines.** Everything in `sspi_tb_config.bsvi` is a
   `` `ifndef `` guarded define, so `--cpol 1` becomes `-D TB_CPOL=1` and lands
   in the Makefile's `TB_DEFINES`.
3. **Clears stale build artifacts.** `bsc` does not re-elaborate when only a
   `-D` changes, so the script deletes the testbench `.bo` and `mkTest.ba`
   before every compile. Without this you silently rerun the previous config.

The Makefile itself is the stock Bluespec example Makefile with the paths and
defines set for this project. `TOPFILE` is passed in by the script when you use
`--tb`. You can call it directly if you want:

```
make TB_DEFINES="-D TB_CPOL=1 -D TB_CPHA=0" all_bsim
```

NOTE: `rtl/dependencies` is on both `-p` and `-I` because
`Logger.bsv` has no package declaration and gets included with `` `include `` rather than
imported.

## Flags

Run with no arguments to get the `sspi_simplex_tx.c` defaults.

**Sources**

| flag | meaning |
| --- | --- |
| `--rtl <file>` | RTL version from `rtl/`. Any version used must declare `package sspi;` |
| `--tb <file>` | testbench from `testbenches/`. Package name must match filename, top module must be `mkTest` |


**RTL**

Different versions of the SSPI RTL that were tested can be found and run from the rtl/ directory.
The file nomenclatures for the RTL as based on the exact modification done to them from the previous default.
Default - ``devices/spi_v2/sspi.bsv`` found in branch `master`


**Transfer configuration**, each mapping to a driver call in `sspi_driver.c`

| flag | default | maps to |
| --- | --- | --- |
| `--nbytes <1-31>` | 8 | `SSPI_SIZE` |
| `--data-size <n>` | 8 | `DATA_SIZE` |
| `--cpol <0\|1>` | 0 | `CLK_POLARITY_LOW/_HIGH` |
| `--cpha <0\|1>` | 0 | `CLK_PHASE_LOW/_HIGH` |
| `--lsb-first` | MSB | `LSB_FIRST` |
| `--setup <n>` | 1 | `SETUP_TIME_CYCLES`, so `cs_t_delay` |
| `--hold <n>` | 0 | `HOLD_TIME_CYCLES`, so `t_cs_delay` |
| `--bitrate <hz>` | 100000 | `sspi_configure_clock_in_hz()`, truncation included |
| `--prescale <n>` | 243 | raw prescaler, bypasses `--bitrate` |

`--setup` and `--hold` are `Bit#(8)` fields. 255 is the tested maximum; 256 fails to
compile with S0027.

**Data**

| flag | default | meaning |
| --- | --- | --- |
| `--data <list>` | off | explicit bytes, e.g. `0xAA,0x55,0xF0`. Also sets `--nbytes` |
| `--seed <hex>` | 0x01 | first byte |
| `--incr <hex>` | 0x01 | increment per byte |

With no `--data` you get the C pattern `01 02 ... 08`. For debugging, use
`--data 0xAA,0x55,0x0F,0xF0,0x01,0xFE,0x69,0x96`. Those eight bytes are all
distinct and none is a bit palindrome, so a failure signature tells you which
fault you are looking at rather than just that one occurred. A repeated byte
like `AA AA AA ...` cannot distinguish a byte swap from a clean transfer.

**Run control**

| flag | meaning |
| --- | --- |
| `--gap <n>` | idle cycles between register accesses (default 4) |
| `--wait <n>` | override the derived settle time |
| `--name <tag>` | tag for the saved output |
| `--save` | write to `sim_results/<name>/`, on failure as well as success |
| `--force` | overwrite an existing results directory |
| `--clean` | `make full_clean` first |
| `--vcd` | generate `dump.vcd` |
| `--verbose` | show the DUT internal trace (`+msspi +l0`) and bsc output |
| `--sweep` | run the cpol x cpha x bit order matrix and summarise |

The `--gap` default of 4 is needed as a separate flag, not cosmetic here. 
A write to `TX_data_rg` only sets a holding register; the byte reaches the 
FIFO one cycle later. Back to back accesses clobber it. On hardware the load 
and store latency in the C loop provides this spacing for free. 
NOTE: the above is an assumption that holds good, hasnt been verified

## Running

### First run after cloning

`rtl/sspi.bsv` is gitignored, because it is only a working copy that `--rtl`
overwrites. A fresh clone therefore has no active RTL, and running the script
with no `--rtl` fails at compile with an unresolved `import sspi`. Name a
variant on the first run and it will be created:

```
./run_sspi_tb.sh --rtl sspi_setup_rx_no_edge_rx.bsv --tb sspi_simplex_tb.bsv \
    --save --name first_run
```

`sspi_setup_rx_no_edge_rx.bsv` is the variant that currently passes everything,
so it is a reasonable starting point. After that, `--rtl` is only needed when
you want to switch variants.

### Single run

```
./run_sspi_tb.sh --rtl sspi_setup_rx_no_edge_rx.bsv --tb sspi_simplex_tb.bsv \
    --cpol 0 --cpha 0 --setup 1 --name my_run --save
```

Full sweep, 240 runs across 10 RTL variants, 3 applications, 4 clock modes and
2 setup values can be run using the given command text file:

```
nohup bash bash_commands_payload.txt > sim_results/sweep.log 2>&1 &
```

NOTE: the sweep.log generated is useless and can be discarded after the run.
Please note that if you have set ``set -o noclobber`` in your bashrc, you will 
have to use >| instead of > in the command, or delete the old log file.

It is 20 blocks, one per RTL variant per setup value, 12 runs each. Each block
clears `build_bsim`, runs its 12, pipes everything to a combined log, then moves
the results into place. Expect roughly 70 minutes.

Run the blocks in order. The `mv` globs match on variant name prefix, and
several variant names are prefixes of others, so out of order runs or leftover
directories in `sim_results/` root can land results in the wrong folder.

`command.txt` is just a scratch file for pasting long commands.

## Results

Every run with `--save` produces a directory containing:

- `run.log`, the full terminal output including the per byte comparison
- `dump.vcd`, for GTKWave
- `config.txt`, the verdict, every parameter, the md5 of the RTL actually used,
  and a copy paste line to reproduce the run

Failures are saved too, run_sspi_tb.sh sorts them as:

```
sim_results/<variant>_runs/setup_time_<n>_runs/<run name>/
```

The md5 checksum in `config.txt` is worth using. It is the hash of `rtl/sspi.bsv` at the
moment of the run, so you can confirm after the fact that a result came from the
RTL you think it did. A sweep across variants can only be verified if those
hashes line up.

A test passes when every byte read back matches what was sent and no read
returned `succ = 0`. Three failure shapes show up in practice: a clean pass, a
completed transfer with wrong data (usually a one bit misalignment, visible in
the signature), and a stall where `RXNE` never asserts and `BUSY` stays high.

## Notes for anyone extending this

New application means a new testbench in `testbenches/`, not a new flag. Keep
the package name equal to the filename and the top module named `mkTest`, and
`--tb` will pick it up. design the testbench modelling the C application is it based on.

Testbench rules that touch the DUT are one shot executions guarded on a state and 
a gap counter, and the gap counter decrement lives in its own rule. This is
deliberate. Any rule calling `mav_read_req` is scheduled more urgent than the
DUT rules it shares state with, so a rule enabled every cycle can starve
`rl_transfer_data_from_rxfifo_to_rxreg` forever. The symptom is every byte
reading back as a copy of the first while `succ` still reports 1.

`mav_read_req` places the byte differently depending on bit order. MSB first
returns `duplicate(rg_rx_data[31:24])`, LSB first returns the whole word with
the oldest byte in `[7:0]`. Both testbenches select on `lsbfirst` accordingly.
This is a read path quirk, not a difference in what was transmitted.


NOTE: 2 additional testcases were created but not yet committed inside the gitlab SDK repos
They are meant to test Half Duplex behaviour of SSPI. We have included them in `application_examples/`
and we have tested them in trisoc and gc2025 simulation setup successfully, a testbench based on that 
model is yet to be created here. TODO

These 2 applications are:
 - sspi_half_duplex_LSB_check.c
 - sspi_half_duplex_MSB_check.c


### FINAL NOTE: 

``sspi_setup_rx_no_edge_rx.bsv`` is the final fixed version of the RTL that passed all tests under all configurations. You can refer to this in docs/SSPI_RTL_testing_report.pdf.

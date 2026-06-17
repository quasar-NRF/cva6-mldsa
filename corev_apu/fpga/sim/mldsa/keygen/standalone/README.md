<!--
==================================================
Giulio Golinelli - golinelli.giulio13@gmail.com
TUMCREATE QUASAR RESEARCH ENGINEER
Modified: 2026-06-17
This file contains modifications vs. the upstream
CVA6 / ML-DSA-OSH source fork.
==================================================
-->

# KeyGen STANDALONE

Tests the ML-DSA-65 accelerator (`combined_top.v`) in KeyGen mode, with **no
AXI bridge**. The testbench drives the accelerator's streaming interface
directly.

## Run

```bash
./run.sh           # default: 1 KAT vector
./run.sh 5         # first 5 KAT vectors
```

## What it does

1. Copies the upstream testbench from
   `ML-DSA-OSH/ref_combined/src_tb/tb_keygen_top.v` and patches:
   - `sec_lvl = 3` (ML-DSA-65)
   - `NUM_TV = 1` (or your argument)
2. Compiles mldsa_params, VHDL Keccak, Verilog accelerator sources, testbench.
3. Elaborates and runs the simulation (10-minute timeout).
4. Greps for `testbench done` and `WRONG` to determine pass/fail.

## What it produces

- `PK`: 1952 bytes / 244 words
- `SK`: 4032 bytes / 504 words

Both are compared byte-for-byte against the NIST KeyGen KAT.

## Pass criterion

Zero `WRONG` byte mismatches in the log.

## Files generated in this dir (gitignored)

- `tb_keygen_top_sim.v` — patched testbench (regenerated each run)
- `run.log` — short status log
- `xsim_output.log` — full xsim output
- `xsim.dir/`, `webtalk*`, `*.log` — Vivado sim byproducts

## Source files exercised

- `ML-DSA-OSH/ref_combined/src/*.v` — accelerator
- `ML-DSA-OSH/ref_combined/src/*.vhd` — Keccak hash
- `ML-DSA-OSH/ref_combined/src_tb/tb_keygen_top.v` — upstream testbench
- `ML-DSA-OSH/KAT/KeyGen_seed_65.txt` + `KeyGen_pk_65.txt` + `KeyGen_sk_65.txt`

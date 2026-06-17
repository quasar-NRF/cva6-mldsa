# ML-DSA-65 FPGA Integration — Simulation Tests

This directory contains self-contained simulation tests for the ML-DSA-65
post-quantum signature accelerator integrated into the CVA6 RISC-V FPGA design.

## What is being tested

ML-DSA-65 (FIPS 204, Module-Lattice Digital Signature Algorithm, security level 3)
has three operational phases:

| Phase   | Input                                  | Output                          |
|---------|----------------------------------------|---------------------------------|
| KeyGen  | 256-bit random seed                    | PK (1952 B) + SK (4032 B)       |
| Sign    | SK + message + randomness              | Signature (3309 B)              |
| Verify  | PK + signature + message               | 1 bit (0=valid, 1=invalid)      |

Each phase is tested in **two configurations**:

1. **standalone** — The accelerator (`combined_top.v`) is driven directly via
   its streaming interface (valid/ready/data). This isolates accelerator
   correctness from any bridge/AXI concerns.

2. **bridge** — The accelerator sits behind `axi_mldsa_bridge`, and an AXI4
   master BFM in the testbench drives the bridge. This is the exact path the
   CVA6 CPU uses at runtime: memory-mapped reads/writes at `0x50000000`.

## Directory layout

```
sim/mldsa/
├── README.md                  ← you are here
├── keygen/
│   ├── standalone/run.sh      ← accelerator-only KeyGen
│   └── bridge/run.sh          ← bridge + accelerator KeyGen
├── sign/
│   ├── standalone/run.sh      ← accelerator-only Sign
│   └── bridge/run.sh          ← bridge + accelerator Sign
├── verify/
│   ├── standalone/run.sh      ← accelerator-only Verify
│   └── bridge/run.sh          ← bridge + accelerator Verify
└── e2e/
    ├── standalone/run.sh      ← chained KeyGen→Sign→Verify, accelerator only
    └── bridge/run.sh          ← chained KeyGen→Sign→Verify, through bridge
```

## How to run

Each subdirectory has a `run.sh` script that is fully self-contained — it
compiles all required sources (ML-DSA-OSH accelerator, pulp-platform AXI,
testbench) and runs the simulation.

```bash
cd corev_apu/fpga/sim/mldsa/keygen/standalone
./run.sh               # default: 1 KAT vector
./run.sh 5             # first 5 KAT vectors
```

The script prints progress, the simulation tail output, and a final
`RESULT: PASS` or `RESULT: FAIL` banner. Exit code is 0 on PASS, non-zero
otherwise.

## Pass criteria

- **KeyGen**: output PK and SK match the NIST KeyGen KAT byte-for-byte.
- **Sign**: output signature matches the NIST SigGen KAT byte-for-byte.
- **Verify**: output fail bit matches the NIST SigVer KAT expected value.

KAT vectors are loaded from `core_apu/fpga/src/ML-DSA-OSH/KAT/*.txt`.

## Tools required

- Xilinx Vivado 2025.2 simulator (`xvlog`/`xvhdl`/`xelab`/`xsim` at
  `/opt/Xilinx/2025.2/Vivado/bin/`)
- The CVA6 project tree with `vendor/pulp-platform/{axi,common_cells}`
  submodules checked out (only needed for bridge tests)

## What each test proves

| Test               | Proves                                                                  |
|--------------------|-------------------------------------------------------------------------|
| keygen standalone  | The accelerator alone produces correct PK+SK from a seed                |
| keygen bridge      | The bridge FIFO + 2-phase start path delivers the seed and drains PK+SK |
| sign standalone    | The accelerator alone produces a correct signature from SK+message      |
| sign bridge        | The bridge handles the larger Sign input stream (~515 words)            |
| verify standalone  | The accelerator alone correctly accepts/rejects signatures              |
| verify bridge      | The bridge correctly delivers the ~1000-word Verify input stream        |

If all six pass, the FPGA integration is functionally correct in simulation.
Remaining work (FPGA build, on-HW verification) is tracked separately.

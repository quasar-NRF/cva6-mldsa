<!--
==================================================
Giulio Golinelli - golinelli.giulio13@gmail.com
TUMCREATE QUASAR RESEARCH ENGINEER
Modified: 2026-06-17
This file contains modifications vs. the upstream
CVA6 / ML-DSA-OSH source fork.
==================================================
-->

# CVA6-MLDSA — Post-Quantum Signature Accelerator on RISC-V

Fork of the [OpenHWGroup `cva6`](https://github.com/openhwgroup/cva6)
64-bit RISC-V core, integrated with the
[ML-DSA-65](https://doi.org/10.6028/NIST.FIPS.204) post-quantum digital
signature accelerator (FIPS 204, Module-Lattice Digital Signature
Algorithm) via a memory-mapped AXI bridge. Target platform: Digilent
Genesys2 FPGA (Xilinx Kintex UltraScale).

This repository is the **system integration** layer; the accelerator
itself lives in the
[`quasar-NRF/ML-DSA-OSH`](https://github.com/quasar-NRF/ML-DSA-OSH)
submodule (itself a fork of
[`KULeuven-COSIC/ML-DSA-OSH`](https://github.com/KULeuven-COSIC/ML-DSA-OSH)
with bridge-context fixes).

## What's in this fork

- `corev_apu/fpga/src/axi_mldsa_bridge.sv` — AXI4 slave → accelerator
  streaming-IO bridge (64-bit data, register-mapped CTRL/DATA_IN/DATA_OUT
  /STATUS).
- `corev_apu/fpga/src/ariane_xilinx.sv` — top-level FPGA design with the
  accelerator and bridge wired into the SoC address map.
- `corev_apu/tb/ariane_soc_pkg.sv` — address-map package with the
  accelerator's AXI base.
- `corev_apu/fpga/sim/mldsa/` — Vivado XSIM testbench suite, 8 tests:
  keygen/sign/verify × standalone/bridge + end-to-end chained. All pass
  against the NIST KAT vectors (sec_lvl=3).
- `corev_apu/fpga/sw/` — bare-metal RISC-V test programs
  (`mldsa_*_test.c`, `mldsa_*_diag.c`) and the deployment script
  `deploy_test.sh` (program FPGA + UART capture + auto-pass/fail).
- `corev_apu/fpga/scripts/` — fast-rebuild TCL helpers for the Vivado
  flow.
- Documentation: `CVA6_MLDSA_INTEGRATION.md` (full design + debug log),
  `MLDSA_BUGS_REPORT.md` (upstream vs. bridge-context bugs),
  `MLDSA_FPGA_TIMING_REPORT.md` (utilization + HW timing estimates),
  `PROJECT_STATUS.md`.

## Simulation status (all green)

| Phase    | Standalone | Bridge | Notes                                |
|----------|-----------|--------|--------------------------------------|
| KeyGen   | PASS      | PASS   | pk/sk byte-exact vs NIST KAT         |
| Sign     | PASS      | PASS   | signature byte-exact vs NIST KAT     |
| Verify   | PASS      | PASS   | fail bit matches NIST expected       |
| End-to-end | PASS    | PASS   | chained KeyGen → Sign → Verify       |

Run a single phase from `corev_apu/fpga/sim/mldsa/<phase>/<mode>/run.sh`.

## Quick start

```bash
# 1. Clone with submodule
git clone --recursive https://github.com/quasar-NRF/cva6-mldsa.git
cd cva6-mldsa

# 2. Run the standalone KeyGen simulation
cd corev_apu/fpga/sim/mldsa/keygen/standalone
./run.sh 1           # 1 KAT vector; pass/fail printed at end
```

See `CVA6_MLDSA_INTEGRATION.md` for FPGA build, program, and debug flows.

## Repository layout

```
cva6-mldsa/
├── core/                              # upstream CVA6 core (untouched)
├── corev_apu/
│   ├── fpga/
│   │   ├── sim/mldsa/                 # NEW: XSIM testbench suite
│   │   ├── src/
│   │   │   ├── ML-DSA-OSH/            # submodule (quasar-NRF/ML-DSA-OSH)
│   │   │   ├── axi_mldsa_bridge.sv    # NEW: AXI ↔ accelerator bridge
│   │   │   └── ariane_xilinx.sv       # modified: wires bridge into SoC
│   │   └── sw/                        # NEW: bare-metal test firmware
│   └── tb/ariane_soc_pkg.sv           # modified: address map
├── CVA6_MLDSA_INTEGRATION.md          # primary design doc
├── MLDSA_BUGS_REPORT.md
├── MLDSA_FPGA_TIMING_REPORT.md
└── PROJECT_STATUS.md
```

## Accelerator programming interface (64-bit AXI)

| Offset | Reg       | R/W | Meaning                                              |
|--------|-----------|-----|------------------------------------------------------|
| 0x00   | CTRL      | WO  | bit0=start, bits[2:1]=mode, bits[5:3]=sec_lvl        |
| 0x08   | DATA_IN   | WO  | push 64-bit word into accelerator input FIFO         |
| 0x10   | DATA_OUT  | RO  | pop 64-bit word from accelerator output FIFO         |
| 0x18   | STATUS    | RO  | bit0=done, bit1=fail, bit2=input_empty, bit3=out_full|

Modes: `0=KeyGen, 1=Sign, 2=Verify`. Security levels `2/3/5` are
selectable at runtime via CTRL[5:3].

## Upstream attribution

The CVA6 core is © OpenHW Group, Apache-2.0. The ML-DSA-OSH accelerator
is © KU Leuven COSIC, MIT. See `LICENSE` and the submodule for details.
This fork's integration work is released under the same licenses.

## Author

Giulio Golinelli — `golinelli.giulio13@gmail.com`
TUMCREATE — QUASAR Research Engineer

## References

- FIPS 204, *Module-Lattice Digital Signature Algorithm*,
  [NIST (2024)](https://doi.org/10.6028/NIST.FIPS.204).
- Beckwith et al., *NTT Multiplication for NTT-Unfriendly Rings…*,
  [IACR ePrint 2021/1451](https://eprint.iacr.org/2021/1451).
- CVA6 user manual — <https://docs.openhwgroup.org/projects/cva6-user-manual/>.

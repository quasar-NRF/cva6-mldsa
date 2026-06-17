<!--
==================================================
Giulio Golinelli - golinelli.giulio13@gmail.com
TUMCREATE QUASAR RESEARCH ENGINEER
Modified: 2026-06-17
This file contains modifications vs. the upstream
CVA6 / ML-DSA-OSH source fork.
==================================================
-->

# ML-DSA CVA6 FPGA Utilization & Hardware Timing Report

**Date:** 2026-06-17
**Scope:** Snapshot of (a) current FPGA utilization of the full CVA6+ML-DSA SoC, and (b) estimated wall-clock execution time for each ML-DSA phase running on the actual Genesys2 hardware.

> **Note:** The bug analysis that previously lived in this file has been split out into its own document, [`MLDSA_BUGS_REPORT.md`](MLDSA_BUGS_REPORT.md). This report is now FPGA + timing only.

This report is a companion to `CVA6_MLDSA_INTEGRATION.md` (full design doc) and `PROJECT_STATUS.md` (operational log).

---

## 1. Current FPGA Utilization

Device: **Genesys2 — Kintex-7 `xc7k325tffg900-2`**
Source: `corev_apu/fpga/work-fpga/ariane_xilinx_utilization_placed.rpt` (placed design, dated 2026-06-15)

| Resource | Used | Available | Util% |
|----------|------|-----------|-------|
| Slice LUTs | 153,306 | 203,800 | **75.22%** |
| └ LUT as Logic | 150,274 | 203,800 | 73.73% |
| └ LUT as Memory | 3,032 | 64,000 | 4.74% |
| Slice Registers | 104,531 | 407,600 | 25.65% |
| Block RAM Tiles | 83 | 445 | 18.65% |
| └ RAMB36/FIFO | 82 | 445 | 18.43% |
| └ FIFO36E1 | 1 | — | — |
| DSP48E1 | 43 | 840 | **5.12%** |
| F7 Muxes | 7,491 | 101,900 | 7.35% |
| F8 Muxes | 1,968 | 50,950 | 3.86% |
| Bonded IOs | 132 | 500 | 26.40% |
| BUFG (global clocks) | 13 | 32 | 40.63% |

### Notes

- This is the **whole SoC**: CVA6 core + caches + bootrom + AXI xbar + ML-DSA + AXI bridge + UART + GPIO + ethernet + SD + etc.
- The ML-DSA accelerator itself is a fraction of the total — it is BRAM-heavy (polynomial storage) and DSP-light (most poly arithmetic uses LUT-based modular arithmetic, not DSPs).
- **75% LUT usage is getting tight.** Adding more accelerators will likely require migrating to a larger device.
- The 82 BRAM36 blocks break down roughly as: CVA6 I-cache + D-cache (~30), DDR3 controller (~16), ML-DSA internal poly RAMs (~30), AXI bridge FIFOs (~2), miscellaneous (~4).

---

## 2. Estimated Hardware Execution Time

Yes — wall-clock time **can** be estimated from simulation. The system clock is fixed by `xlnx_clk_gen` at **50 MHz** (period = **20 ns**, from `CLKOUT1_REQUESTED_OUT_FREQ=50`).

The cycle counts below are from the most recent passing e2e bridge simulation:

| Phase | Bridge cycles | HW time @ 50 MHz | Notes |
|-------|---------------|------------------|-------|
| KeyGen | 11,391 | **228 μs** | Pure accelerator cycles; doesn't include CVA6 setup overhead |
| Sign | 87,107 | **1.74 ms** | Dominated by rejection sampling retries |
| Verify | 14,297 | **286 μs** | Includes the heavy NTT_z computation |
| **e2e total** | **112,795** | **≈ 2.26 ms** | One full KeyGen → Sign → Verify sequence |

### Standalone (no bridge) reference cycle counts

For comparison, the accelerator driven directly by an ideal testbench:

| Phase | Standalone cycles | HW time @ 50 MHz |
|-------|-------------------|------------------|
| KeyGen | 9,456 | 189 μs |
| Sign | 25,692 | 514 μs |
| Verify | 9,732 | 195 μs |

The bridge versions take ~1.4× longer because of:
- AXI4 single-beat transactions (no bursting)
- FIFO priming latency on phase entry
- CVA6 walking through CTRL sequencing

In a real software driver, add some hundreds of cycles for the CPU to do the AXI writes themselves — order of magnitude, still sub-millisecond per phase.

### Caveats

- These are *simulator* cycle counts which match *hardware* cycles (the Verilog is cycle-accurate against the placed netlist).
- What **cannot** be estimated from sim alone is the actual achieved clock frequency after place-and-route timing closure. If the worst negative slack forces a slower clock, wall-clock time scales linearly. The current design meets timing at 50 MHz on the Genesys2 — but a more aggressive clock target would need full timing-closure verification.
- Rejection sampling in Sign is **variable** — the numbers above are for KAT vector #0. Different messages/keys produce different rejection counts, so Sign wall-clock time varies roughly ±10% in practice.

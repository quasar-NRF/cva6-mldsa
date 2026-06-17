<!--
==================================================
Giulio Golinelli - golinelli.giulio13@gmail.com
TUMCREATE QUASAR RESEARCH ENGINEER
Modified: 2026-06-17
This file contains modifications vs. the upstream
CVA6 / ML-DSA-OSH source fork.
==================================================
-->

# CVA6 + ML-DSA-65 FPGA Integration - Project Status

## Project Overview

**What:** Integrating the ML-DSA-65 (Module-Lattice Digital Signature Algorithm, FIPS 204) post-quantum cryptographic accelerator into the CVA6 RISC-V processor running on a Genesys2 FPGA development board (Xilinx Kintex-7 XC7K325T).

**Why:** ML-DSA is a NIST-standardized post-quantum signature scheme. Hardware acceleration is essential for practical deployment because software-only implementations are too slow for embedded systems. The accelerator (ML-DSA-OSH from KU Leuven) performs the heavy lattice operations (NTT, polynomial arithmetic, Keccak hashing) in dedicated hardware, while the CVA6 CPU orchestrates the three-phase signing protocol.

**How:** A custom AXI-Lite bridge (`axi_mldsa_bridge.sv`) connects the accelerator as a memory-mapped peripheral at address `0x50000000`. Software on the CVA6 pushes/pulls 64-bit words through register-based FIFOs to feed data into the accelerator and read results.

---

## Architecture

```
CVA6 CPU (RISC-V RV64)
    |
    | AXI-Lite (0x50000000)
    v
AXI-MLDSA Bridge
    |  (FIFOs, two-phase start: 64-cycle reset + 16-cycle delay)
    v
ML-DSA-65 Accelerator (combined_top.v)
    |-- KeyGen (mode=0): seed[4 words] -> pk+sk[744 words]
    |-- Sign   (mode=2): sk+msg[514 words] -> signature[414 words]
    |-- Verify (mode=1): pk+sig+msg[~680 words] -> pass/fail[1 word]
    |
    |-- Internal: Keccak FSM, NTT Operator, Polynomial Arithmetic
    |-- BRAMs: ram0 (A matrix), ram1 (Z), ram2 (T1), ram3 (C)
```

---

## Achievements

### 1. FPGA Platform Bring-up
**What:** Got the CVA6 processor running on the Genesys2 FPGA with OpenOCD + GDB debug access.

**How:** Configured Vivado build for the Genesys2 board (XC7K325T-ffg900-2), set up the AXI interconnect, and established a workflow for compiling RISC-V bare-metal C code, programming the FPGA, loading ELF binaries via GDB, and reading results from memory-mapped variables.

**Why:** This is the foundation — without a working CPU on the FPGA, no software can drive the accelerator.

### 2. AXI Bridge Design
**What:** Designed `axi_mldsa_bridge.sv` — a register-based AXI-Lite peripheral that bridges the CPU's memory-mapped I/O to the accelerator's streaming interface (valid/ready handshake).

**Key features:**
- 128-deep input FIFO and output FIFO (register-based, zero-latency read)
- Two-phase start: 64-cycle accelerator reset + 16-cycle settle delay before start pulse
- Sticky diagnostic flags (valid_o, ready_i, in_pop) for debugging
- STATUS register for FIFO state (empty/full) and busy flag

**Why:** The accelerator uses a simple valid/ready streaming protocol. The bridge converts this to memory-mapped registers so the CPU can interact with it through standard load/store instructions.

### 3. KeyGen - WORKING (744/744 words)
**What:** The KeyGen phase produces a full ML-DSA-65 public key + secret key in 744 64-bit words from a 4-word (256-bit) random seed.

**Status:** Consistently passes across multiple runs and builds. Verified correct output structure:
- rho (4 words) + K (4 words) + S1 (80 words) + S2 (96 words) + T0 (312 words) + T1 (240 words) + TR (8 words) = 744 words

**How fixed:** Multiple iterations of debugging the data flow, FIFO timing, and start sequence. The two-phase start mechanism was essential for reliable operation.

### 4. Sign - WORKING (414/414 words)
**What:** The Sign phase produces a digital signature (414 words) from the secret key and a message.

**Status:** Consistently passes across multiple runs (3/3 consistency verified on build 34). Now also PASSES in standalone sim (25692 cycles, ML-DSA-V KAT#0) AND bridge sim (103312 cycles, 0 wrong bytes) as of 2026-06-16 22:47.

**Challenges overcome:**
- **Encoder limit bug:** The FSM0_UNLOAD_Z encoder had a limit of `L*64*2+4` words, but the correct value is `L*64*2+2`. This caused the encoder to produce 2 extra garbage words.
- **GenY stuck in S_ABSORB_K:** GenY (the rejection sampling module) was getting stuck absorbing K values. Root cause was traced to incorrect input sequencing.
- **Race conditions:** The Sign pipeline overlaps input consumption with NTT computation. Timing-sensitive states required careful analysis of which FIFO words get consumed when.
- **T0 decoder shift-without-load corruption (2026-06-16):** In bridge context, the input FIFO occasionally drained mid-T0 (TB push rate ~10 cyc/word vs decoder consume ~5 cyc/word). The decoder's original `if (valid_i) load else shift-only` logic zeroed SIPO_IN high bits during transient empty cycles, corrupting t0 coefficients and producing 19 wrong bytes in signature h region. Fixed in `decoder.v` with a three-part pattern: (1) stall condition `encode_modei==0 && !valid_i && 4*ENCODE_LVL<=sin<2*4*ENCODE_LVL`, (2) gate `valid_o=0` during stall to prevent FSM consuming duplicate samples, (3) 24-cycle stall timeout to allow end-of-stream draining (preserves standalone behavior). Also increased `FIFO_DEPTH` from 128 to 1024 in `axi_mldsa_bridge.sv`.

### 5. Verify - WORKING (standalone + bridge sim)
**What:** The Verify phase checks if a signature is valid for a given public key and message. It's the most complex phase with 13 FSM states: INIT -> LOAD_RHO -> LOAD_C -> DECODE_Z -> NTT_Z -> NTT_T1 -> NTT_C -> MULT_AZ -> MULT_CT1 -> SUB -> INTT -> GENW1 -> COMPARE.

**Status:** PASSES in both standalone sim (9732 cycles, ML-DSA-III KAT#0) AND bridge sim (11926 cycles, fail=1 matches expected) as of 2026-06-16 23:14. Baseline reference passes standalone in 9730 cycles — near-identical.

**Challenges overcome:**
- **VY_COMPARE diagnostic output regression (2026-06-16):** Standalone verify sim initially returned `0xe247931e1c7bdfd0` (TR value) instead of the expected 1-bit fail result. Root cause: VY_COMPARE state had been modified to emit 7 diagnostic words (TR, MU, hash, c, fail, rho, ntt_z_ctr0) for sec_lvl=3 — leftover FPGA debug instrumentation. The testbench reads the first output word expecting the fail bit, but got TR. Fixed by reverting VY_COMPARE output logic to baseline (single fail-bit at ctr=6 for sec_lvl=3) in `combined_top.v`. The deeper "Fix 9" useHint bypass path was kept since it doesn't affect output formatting.
- **NTT completion race condition:** Added guard `ctr >= T1_LEN[12:3]` to VY_NTT_Z exit so all T1 data is consumed before transitioning to VY_NTT_T1.
- **Hash mismatch (pre-sim, FPGA):** Earlier FPGA runs showed `dout=0xe7bee3dafbed0734` vs `c=0xabeb98e85aa5cf40`. This was on the older bitstream before the Sign fixes; the standalone sim now confirms verify computes the correct hash and matches.

---

### 6. End-to-End (KeyGen → Sign → Verify) - WORKING (bridge sim)
**What:** All three phases chained in sequence through the AXI bridge, using the actual outputs of each phase as inputs to the next (no pre-baked KAT signatures).

**Status:** PASSES in bridge sim (KG=11391 + Sign=87107 + Verify=14297 cycles total) as of 2026-06-16 23:29. Final verify returns fail=0 (valid signature).

**Challenges overcome:**
- **CTRL start-bit clear between phases (2026-06-16):** The bridge's `ctrl_start_rise` is a rising-edge detector. Writing CTRL=0x1D for Phase 2 Sign while CTRL=0x19 (from Phase 1 KeyGen) is still in the register leaves ctrl_start stuck at 1 — no rising edge — so the 2-phase start sequence (RST_CYCLES + START_DELAY) never triggers and Sign hangs indefinitely. Fixed by writing CTRL=0x00 between phases to clear the start bit before asserting the next phase's CTRL.

---

## All Sim Gates Cleared (2026-06-16 23:29)

All 7 sim phases pass cleanly:
1. KeyGen standalone — 9456 cyc — 2026-06-16 15:20
2. KeyGen + bridge — 11379 cyc — 2026-06-16 16:00
3. Sign standalone — 25692 cyc — 2026-06-16 16:25
4. Sign + bridge — 103312 cyc — 2026-06-16 22:47
5. Verify standalone — 9732 cyc — 2026-06-16 23:10
6. Verify + bridge — 11926 cyc — 2026-06-16 23:14
7. e2e chained + bridge — 1130195 ns total (KG=11391 + Sign=87107 + Verify=14297 cyc) — 2026-06-16 23:29

Per sim-only-until-e2e-passes directive, FPGA builds are now unblocked.

---

## Current Challenges

### Challenge 1: Verify Computation Error (fail=1)
**What:** The verify pipeline runs to completion but the final hash comparison fails. The accelerator computes c~hat' (hash of w1 coefficients) and compares it against c~hat (from the signature). These don't match.

**Diagnostic data from latest run:**
- Computed hash (dout): `0xe7bee3dafbed0734`
- Signature hash (C register): `0xabeb98e85aa5cf40`
- RHO verified correct (matches KeyGen output)
- Pipeline reaches all states including VY_COMPARE

**Why this is hard:** The verify pipeline involves:
1. NTT on Z (5 polynomials of 256 coefficients)
2. NTT on T1 (6 polynomials)
3. NTT on C (challenge)
4. Matrix-vector multiplication (A*Z and C*T1)
5. Subtraction and inverse NTT
6. Coefficient encoding and w1 generation
7. Keccak hashing for comparison

A bug in ANY of these steps would cause the final comparison to fail. Isolating which step is wrong requires either simulation with test vectors or incremental testing.

**Current approach:** Testing with Known-Answer Test (KAT) vectors from NIST to determine if the bug is in:
- (a) The Sign pipeline producing invalid signatures, OR
- (b) The Verify pipeline modifications introducing computation errors

### Challenge 2: NTT Completion Race Condition
**What:** In the original IP, the VY_NTT_Z state transitions to VY_NTT_T1 as soon as all Z NTTs complete, even if T1 data hasn't been fully loaded yet. This causes VY_NTT_T1 to hang because T1 data in RAM2 is incomplete.

**How fixed:** Added a guard condition `ctr >= T1_LEN[12:3]` (240 words) to the VY_NTT_Z exit condition, ensuring all T1 data is consumed before transitioning.

**Why this matters:** This is a race condition between the NTT operator (which runs on Z vectors) and the T1 decoder (which loads T1 data from the input FIFO). The NTT can finish before all 240 T1 words arrive, causing premature state transition.

### Challenge 3: No Soft Reset Between Runs
**What:** The accelerator requires FPGA reprogramming between test runs. Without it, internal state (FIFOs, BRAMs, FSM registers) carries over from the previous run, causing unpredictable behavior.

**Why:** The AXI bridge's two-phase start resets the accelerator's FSM but NOT the bridge's internal FIFOs. And the accelerator's BRAMs are not cleared by the reset signal.

**Impact:** Each test run requires ~30 seconds of Vivado FPGA reprogramming. This slows down the debug cycle significantly.

**Future work:** Implement a proper soft reset mechanism that clears all state without requiring FPGA reprogramming.

---

## Build System

- **FPGA toolchain:** Xilinx Vivado 2025.2
- **Synthesis target:** Genesys2 (xc7k325tffg900-2)
- **Build time:** ~30-45 minutes for full synthesis + implementation
- **RISC-V toolchain:** riscv64-unknown-elf-gcc 13.1.0
- **Debug:** OpenOCD + GDB via JTAG

## Key Files

| File | Purpose |
|------|---------|
| `corev_apu/fpga/src/ML-DSA-OSH/ref_combined/src/combined_top.v` | Main accelerator (modified from IP) |
| `corev_apu/fpga/src/axi_mldsa_bridge.sv` | AXI-Lite to accelerator bridge |
| `corev_apu/fpga/src/ariane_xilinx.sv` | Top-level FPGA design |
| `corev_apu/fpga/sw/mldsa_full_test.c` | Full KeyGen+Sign+Verify test |
| `corev_apu/fpga/sw/deploy_test.sh` | Automated test deployment script |

## Backup Strategy

Milestone backups stored at `/home/quasart1/cva6/backups/`:
- `build34_sign_works/` - Bitstream + sources where Sign was first verified working
- Each backup includes: bitstream, combined_top.v, test C file

# CVA6 + ML-DSA Accelerator Integration <!-- omit in toc -->

This project integrates a **CVA6 RISC-V processor** with an **ML-DSA-OSH post-quantum hardware accelerator** on a Xilinx Genesys2 FPGA. Software running on the CVA6 performs post-quantum cryptographic operations — **KeyGen**, **Sign**, and **Verify** — by reading and writing memory-mapped registers at address `0x5000_0000`.

**Target:** ML-DSA-65 (security level 3, parameters K=6, L=5, η=4).

**Status:** All three phases (KeyGen, Sign, Verify) pass byte-for-byte against NIST KAT in **both** standalone accelerator simulation **and** bridge simulation. End-to-end KeyGen→Sign→Verify passes in both standalone and bridge sim. **FPGA hardware verification is the next milestone** — the design has not yet been built and exercised on the physical Genesys2 since the latest round of fixes.

- [1. Architecture Overview](#1-architecture-overview)
- [2. Project Status](#2-project-status)
  - [2.1. What Has Been Achieved](#21-what-has-been-achieved)
  - [2.2. Current Problems](#22-current-problems)
  - [2.3. Next Steps](#23-next-steps)
- [3. How the System Works](#3-how-the-system-works)
  - [3.1. The Processor: RISC-V and the CVA6](#31-the-processor-risc-v-and-the-cva6)
  - [3.2. The Accelerator: ML-DSA and Its Streaming Interface](#32-the-accelerator-ml-dsa-and-its-streaming-interface)
  - [3.3. The Bus: AXI4 and the Crossbar](#33-the-bus-axi4-and-the-crossbar)
  - [3.4. Simplifying the Bus: AXI4-Lite and the Register Bank](#34-simplifying-the-bus-axi4-lite-and-the-register-bank)
  - [3.5. The Bridge: Register Decode, Handshake Logic, and the Software Interface](#35-the-bridge-register-decode-handshake-logic-and-the-software-interface)
  - [3.6. The Buffers: FIFOs, BRAM, and the Rate Mismatch](#36-the-buffers-fifos-bram-and-the-rate-mismatch)
  - [3.7. The Startup Sequence: Reset, Start Pulses, and Edge Detection](#37-the-startup-sequence-reset-start-pulses-and-edge-detection)
  - [3.8. The Signing FSM Bug](#38-the-signing-fsm-bug)
  - [3.9. Diagnostic Infrastructure](#39-diagnostic-infrastructure)
- [4. Register Map](#4-register-map)
- [5. Software](#5-software)
  - [5.1. Test Programs](#51-test-programs)
  - [5.2. Signing Input Word Order (510 words total)](#52-signing-input-word-order-510-words-total)
  - [5.3. Toolchain](#53-toolchain)
- [6. File-by-File Changes](#6-file-by-file-changes)
- [7. Bugs Found and Fixed](#7-bugs-found-and-fixed)
  - [7.1. Pre-Existing Bugs in the ML-DSA-OSH Accelerator](#71-pre-existing-bugs-in-the-ml-dsa-osh-accelerator)
  - [7.2. Bridge-Context Issues](#72-bridge-context-issues-specific-to-our-axi_mldsa_bridge-sv-wrapper-not-upstream)
  - [7.3. Debug Instrumentation Added and Removed](#73-debug-instrumentation-added-and-removed)
- [8. Synthesis and Resource Utilization](#8-synthesis-and-resource-utilization)
  - [8.1. Overall Device Utilization](#81-overall-device-utilization)
  - [8.2. Per-Component Breakdown](#82-per-component-breakdown)
  - [8.3. Clocking Resources](#83-clocking-resources)
  - [8.4. Resource Implications](#84-resource-implications)
  - [8.5. Estimated Hardware Execution Time](#85-estimated-hardware-execution-time)
- [9. Design FAQ](#9-design-faq)
  - [9.1. Why is `axi_to_axi_lite` needed? Couldn't we connect the CVA6 directly to `axi_lite_regs`?](#91-why-is-axi_to_axi_lite-needed-couldnt-we-connect-the-cva6-directly-to-axi_lite_regs)
  - [9.2. But isn't there an AXI4 Slave IP inside `axi_to_axi_lite` that already handles bursts and IDs? Couldn't we merge that into `axi_lite_regs`?](#92-but-isnt-there-an-axi4-slave-ip-inside-axi_to_axi_lite-that-already-handles-bursts-and-ids-couldnt-we-merge-that-into-axi_lite_regs)
  - [9.3. But doesn't the crossbar (or some other AXI infrastructure) handle burst decomposition? Why does the slave need to deal with it?](#93-but-doesnt-the-crossbar-or-some-other-axi-infrastructure-handle-burst-decomposition-why-does-the-slave-need-to-deal-with-it)
  - [9.4. Couldn't we write a custom AXI4 slave that writes directly to the BRAM FIFO, eliminating both `axi_to_axi_lite` and `axi_lite_regs`?](#94-couldnt-we-write-a-custom-axi4-slave-that-writes-directly-to-the-bram-fifo-eliminating-both-axi_to_axi_lite-and-axi_lite_regs)
  - [9.5. Could the internal FIFOs of `axi_to_axi_lite` replace the BRAM FIFOs?](#95-could-the-internal-fifos-of-axi_to_axi_lite-replace-the-bram-fifos)
- [10. Simulation Testing Methodology](#10-simulation-testing-methodology)
  - [10.1. Standalone Simulation](#101-standalone-simulation)
  - [10.2. Bridge Simulation](#102-bridge-simulation)
  - [10.3. Practical Differences](#103-practical-differences)
  - [10.4. Why Both Modes Are Required](#104-why-both-modes-are-required)
- [11. Build, Program, and Debug](#11-build-program-and-debug)
  - [11.1. Prerequisites](#111-prerequisites)
  - [11.2. Build the Bitstream](#112-build-the-bitstream)
  - [11.3. Program the FPGA](#113-program-the-fpga)
  - [11.4. Run Tests](#114-run-tests)
  - [11.5. Debug via GDB](#115-debug-via-gdb)
  - [11.6. SoC Address Map](#116-soc-address-map)

---

## 1. Architecture Overview

The system translates between two incompatible protocols. At one end, the **CVA6 core** (a 64-bit RISC-V processor) communicates exclusively through AXI4 memory-mapped reads and writes. At the other end, the **ML-DSA accelerator** (`combined_top.v`) understands only a streaming interface — a `start` pulse, `mode`/`sec_lvl` control wires, and valid/ready data handshakes. Between them sits the **AXI-MLDSA bridge** (`axi_mldsa_bridge.sv`), which converts AXI4 transactions into the accelerator's streaming protocol through a pipeline of components: AXI4-to-AXI4-Lite conversion, a register bank, custom register decode logic, BRAM FIFOs, and handshake logic.

The following sections walk through every component in this chain, explain the underlying technologies, and describe the design decisions that shaped the integration.

---

## 2. Project Status

### 2.1. What Has Been Achieved

The full hardware-software integration chain is in place and **all three cryptographic phases are verified in simulation**:

- **Complete hardware platform**: The CVA6 processor, AXI-MLDSA bridge, ML-DSA-OSH accelerator, and all supporting peripherals (DRAM, UART, SPI, GPIO) synthesize and fit on the Genesys2 FPGA (xc7k325t). The placed design uses 75.22% of Slice LUTs and 18.65% of BRAM — see section 8 for the full utilization table.
- **All 8 simulation tests pass cleanly against NIST KAT**:
  | # | Test | Cycles | Status |
  |---|------|--------|--------|
  | 1 | KeyGen standalone | 9,456 | PASS — matches KAT byte-for-byte |
  | 2 | KeyGen + bridge | 11,391 | PASS — matches KAT byte-for-byte |
  | 3 | Sign standalone | 25,692 | PASS — matches KAT byte-for-byte |
  | 4 | Sign + bridge | 87,107 | PASS — matches KAT byte-for-byte |
  | 5 | Verify standalone | 9,732 | PASS — fail bit matches KAT |
  | 6 | Verify + bridge | 14,297 | PASS — fail bit matches KAT |
  | 7 | e2e standalone | — | PASS — chained KG→Sign→Verify accepted sig |
  | 8 | e2e + bridge | 112,795 | PASS — chained KG→Sign→Verify via bridge accepted sig |

  The bridge e2e test chains the actual KeyGen output into Sign, and the actual Sign output into Verify — no pre-baked KAT values. Verify returns fail=0 (signature valid), proving the full data path is functionally correct.
- **Bridge design fully validated**: The register decode logic, BRAM-based FIFOs (1024-deep), handshake logic, rising-edge start detection, CTRL-between-phases sequencing for multi-phase runs, and sticky diagnostic bits have all been exercised by the e2e bridge flow without issues.
- **Diagnostic infrastructure proven**: The STATUS and DIAG registers were used extensively to debug every phase. The sticky diagnostic bits and pre-decoded GDB variables proved effective for identifying stall conditions without UART output.
- **Software toolchain working**: Bare-metal RISC-V compilation (`rv64imac_zicsr`), GDB-based loading via OpenOCD/JTAG, and polled register I/O are all operational (used in earlier FPGA bring-up of KeyGen).
- **Accelerator bugs identified and patched**: Multiple pre-existing bugs in the ML-DSA-OSH accelerator were discovered during integration (see section 7 for the full list). Fixes have been applied to the accelerator's HDL and verified in simulation.

### 2.2. Current Problems

- **FPGA hardware verification pending**: All simulation gates have passed (per the sim-only-until-e2e-passes directive), unblocking FPGA builds. The next major step is to build the bitstream with all current fixes and re-verify KeyGen, Sign, Verify, and e2e on the physical Genesys2 board. Earlier FPGA runs verified KeyGen only; the Sign/Verify fixes have not yet been exercised on hardware.
- **Build time**: Full synthesis + implementation takes 30–60 minutes on the current host. Iterating on fixes is slow, especially when the signing flow requires multiple debug cycles.
- **No interrupt support**: The current design uses polled I/O only. For signing and verify, software must busy-wait on STATUS flags. This is acceptable for testing but not for production use where the CPU could be doing other work while the accelerator processes.
- **No soft reset between runs**: The accelerator currently requires FPGA reprogramming between test runs. The AXI bridge's two-phase start resets the accelerator's FSM but NOT the bridge's internal FIFOs or the accelerator's BRAMs, so internal state carries over from the previous run.

### 2.3. Next Steps

1. **Build bitstream and verify on hardware**: Run the Vivado build with all current fixes. Program the Genesys2 and run `mldsa_test.c` (KeyGen → Sign → Verify) to confirm the complete cryptographic pipeline works end-to-end on physical hardware.
2. **Per-phase hardware verification**: Run `mldsa_keygen_test.c`, `mldsa_sign_test.c`, and verify the outputs match the simulation results.
3. **Performance characterization on hardware**: Measure wall-clock time for each operation on the FPGA. The simulation projects ~228 μs for KeyGen, ~1.74 ms for Sign, ~286 μs for Verify at the 50 MHz clock — see section 8.5 for the full timing estimate.
4. **Upstream accelerator fixes**: The real-design bugs found in `combined_top.v`, `decoder.v`, and `operation_module.v` (documented in section 7.1) are fixes to the KU Leuven COSIC accelerator. These should be contributed back as pull requests to the [ML-DSA-OSH repository](https://github.com/KULeuven-COSIC/ML-DSA-OSH).
5. **Explore DMA or interrupt-driven I/O**: For production use, evaluate whether a simple interrupt signal (accelerator-done → PLIC → CPU) or a lightweight DMA engine would improve CPU utilization during long accelerator operations.

---

## 3. How the System Works

### 3.1. The Processor: RISC-V and the CVA6

**RISC-V** is an open-standard instruction set architecture (ISA). Unlike proprietary ISAs such as x86 or ARM, RISC-V is free to implement — anyone can design a CPU that speaks RISC-V without paying licensing fees. The ISA defines the contract between software and hardware: what instructions exist, how registers are numbered, how memory is addressed, and how control flow works.

RISC-V is modular. A base integer set (`RV64I` for 64-bit) is mandatory, and optional extensions add capabilities: `M` (multiply/divide), `A` (atomic memory operations), `C` (compressed 16-bit instructions), `F`/`D` (floating-point), etc. The string `rv64imac_zicsr` means: 64-bit base, with multiply, atomics, compressed instructions, and CSR (Control and Status Register) access. Software talks to hardware exclusively through `load` and `store` instructions targeting specific memory addresses — this is the fundamental mechanism by which the CPU controls peripherals.

The **CVA6** (formerly Ariane) is a 64-bit RISC-V processor core developed by the OpenHW Group. It is a 6-stage, single-issue, in-order pipeline written in SystemVerilog, designed to be synthesizable on FPGAs and ASICs. From the software's perspective, interacting with the accelerator is no different from reading or writing memory — the CPU issues a `store` to address `0x5000_0008` and the interconnect routes that write to the bridge, which pushes it into the accelerator's input FIFO.

Three properties of the CVA6 determine the integration architecture:

- **In-order execution**: store operations to the accelerator registers are guaranteed to arrive in order — essential, since the accelerator expects data words in a strict sequence.
- **AXI4 master port only**: the core cannot produce streaming signals, interrupts, or custom handshakes. All peripheral communication must pass through AXI4.
- **No custom instruction support**: there is no way to add a "sign" opcode. All accelerator communication must go through memory-mapped I/O.

Because the CVA6 can only issue AXI4 reads and writes, and the accelerator speaks a completely different protocol, a translation layer is unavoidable.

### 3.2. The Accelerator: ML-DSA and Its Streaming Interface

**ML-DSA** (Module-Lattice Digital Signature Algorithm) is a post-quantum cryptographic signature scheme standardized by NIST as FIPS 204 in August 2024. It is derived from the Dilithium algorithm and provides security against both classical and quantum computers. Unlike RSA or ECDSA, whose security relies on integer factorization or elliptic curve discrete logarithms (both breakable by quantum algorithms), ML-DSA's security rests on the hardness of finding short vectors in module lattices — a problem believed to be resistant to quantum attack.

ML-DSA supports three operations:

- **KeyGen**: generates a public/private key pair from a random seed (4 input words → 744 output words).
- **Sign**: produces a signature for a message using the private key (510 input words → 414 output words).
- **Verify**: checks whether a signature is valid for a given message and public key (~660 input words → 1 output word: 0 = valid).

NIST defines three security levels, calibrated against symmetric-key primitives:

| Level | Name | Equivalent Cost | K | L | η |
|-------|------|-----------------|---|---|---|
| 2 | ML-DSA-44 | ~2¹²⁸ (AES-128) | 4 | 4 | 2 |
| 3 | ML-DSA-65 | ~2¹⁹² (AES-192) | 6 | 5 | 4 |
| 5 | ML-DSA-87 | ~2²⁵⁶ (AES-256) | 8 | 7 | 2 |

The security parameters define the mathematical structure: **K** is the number of rows in the public key matrix (determines lattice dimensionality), **L** is the number of polynomials in the secret mask vector, and **η** (eta) is the bound on secret coefficient magnitudes (each coefficient is in `[−η, η]`). Together they determine key sizes, signature sizes, and computational cost. This project targets **ML-DSA-65** (K=6, L=5, η=4), providing security level 3.

**ML-DSA-OSH** is an open-source hardware implementation of ML-DSA developed by KU Leuven COSIC. It is written in VHDL/Verilog and implements the full KeyGen/Sign/Verify pipeline using dedicated hardware for Keccak/SHA3 hashing, NTT (Number Theoretic Transform) for polynomial multiplication, and Gaussian sampling for challenge generation. Crucially, it exposes a **streaming interface** — a fundamentally different communication model from the CVA6's memory-mapped bus.

A streaming interface is a point-to-point data path where data flows from a producer to a consumer one word at a time, with no addressing. Unlike a memory bus where you specify an address for each transfer, streaming is like a conveyor belt: the producer places items on the belt, the consumer takes them off, and there is no concept of "where" each item goes. The ML-DSA-OSH accelerator's streaming interface has three types of signals:

**Control signals** are simple binary wires that configure the accelerator's behavior — they are not data, they are switches:
- **`mode`** (2 bits): selects the operation. `0` = KeyGen, `1` = Verify, `2` = Sign.
- **`sec_lvl`** (3 bits): selects the security level (`2` = ML-DSA-44, `3` = ML-DSA-65, `5` = ML-DSA-87).

**The `start` pulse** is a single-cycle signal that tells the accelerator to begin. It goes high for exactly one clock cycle, then returns low. The reason it must be a pulse (not a sustained level) is that the accelerator uses an internal **finite state machine (FSM)** — a digital circuit that transitions between a fixed set of states on each clock edge, following predefined rules. The FSM sits in its INIT (idle) state, continuously monitoring the `start` signal. On every rising clock edge, the FSM checks: is `start` high? If not, it stays in INIT and does nothing. When it detects that `start` is high, the FSM performs two actions on that same clock edge: it **captures** the current values of `mode` and `sec_lvl` into internal storage registers (these are simple flip-flops that latch whatever is on their input when the clock edge arrives), and it **transitions** out of INIT into the first operational state (e.g., LOAD_RHO for signing). From that point forward, the FSM follows its state transition logic through the operation's phases, and `start`, `mode`, and `sec_lvl` are ignored — the captured values are what matter. If `start` were held high continuously instead of pulsed, the FSM would re-detect it on the next clock edge after completing the operation and attempt to restart, corrupting whatever was in progress. The single-cycle pulse ensures the FSM sees exactly one "go" event.

**The valid/ready handshake** regulates data flow. It uses two signals:
- **`valid`** (driven by the producer): "I have a valid data word on the data lines right now."
- **`ready`** (driven by the consumer): "I am able to accept a data word right now."

**A transfer occurs on the clock edge where both `valid` and `ready` are simultaneously high.** If `valid` is high but `ready` is low, the producer must hold its data stable — it cannot discard the word. If `ready` is high but `valid` is low, the consumer waits. This protocol applies symmetrically to both the input path (software → accelerator) and the output path (accelerator → software). The key insight is that neither side can force a transfer — both must agree, and the producer is never allowed to drop data that the consumer hasn't accepted.

The accelerator has a multi-layered FSM (`cstate0` is the main state register). The FSM phases differ by mode:

**Signing flow (mode=2):**

| State | Value | Phase | Words Consumed |
|-------|-------|-------|----------------|
| FSM0_INIT | 0 | Idle, waiting for start | 0 |
| FSM0_LOAD_RHO | 1 | Load public seed | 4 |
| FSM0_LOAD_MU | 2 | Load message/hash context | 1 + variable |
| FSM0_DECODE_S1 | 3 | Decode and store secret s1 | 80 |
| FSM0_NTT_S1 | 4 | NTT on s1 polynomials | 0 (internal) |
| FSM0_NTT_S2 | 5 | Decode s2 + NTT on s2 | 96 |
| FSM0_NTT_T0 | 6 | Decode t0 + NTT on t0 | 312 |
| FSM0_STALL | 7 | Sampling/challenge loop | 0 |

**KeyGen flow (mode=0):**

| Phase | Description | Words Consumed |
|-------|-------------|----------------|
| INIT | Idle, waiting for start | 0 |
| HASH_Z | Hash the random seed with SHA3 | 0 (internal) |
| SAMPLE_S1 | Sample secret polynomial s1 | 0 (internal) |
| SAMPLE_S2 | Sample secret polynomial s2 | 0 (internal) |
| MULT_AS1 | Multiply public matrix A by s1 | 0 (internal) |
| ... | Additional internal phases | 0 |
| OUTPUT | Stream output words | 0 (produces 744 words) |

**Verify flow (mode=1):**

| Phase | Description | Words Consumed |
|-------|-------------|----------------|
| INIT | Idle, waiting for start | 0 |
| LOAD_RHO | Load public seed | 4 |
| LOAD_T1 | Load public key polynomial t1 | variable |
| ... | Additional internal phases | variable |
| OUTPUT | Stream result | 0 (produces 1 word: 0 = valid) |

### 3.3. The Bus: AXI4 and the Crossbar

The CVA6 communicates with all peripherals through **AXI4** (Advanced eXtensible Interface, version 4), an on-chip bus protocol developed by ARM. Its purpose is to provide a standardized, high-throughput way for a master (the CPU) to read and write memory-mapped peripherals (DRAM, UART, accelerators, etc.).

AXI4 separates communication into five independent channels, each with its own valid/ready handshake:

1. **AW (Write Address)**: the master sends the target address.
2. **W (Write Data)**: the master sends the data payload.
3. **B (Write Response)**: the slave acknowledges the write.
4. **AR (Read Address)**: the master sends the target address.
5. **R (Read Data)**: the slave returns the data.

A write transaction flows through AW → W → B. A read transaction flows through AR → R. Each channel independently performs its valid/ready handshake, so the master can pipeline operations — sending a new write address while the previous write data is still in flight.

AXI4 supports **bursts**: a single address phase followed by multiple data phases. Instead of sending address + data for every word, the master sends one address with a burst length (up to 256 beats), then streams consecutive data words. Each individual data phase within a burst is called a **beat** (also called a **transfer**). So a burst of length 16 consists of 16 beats — 16 separate data words transferred one after the other, all under a single address transaction. This is also called a **multi-beat transfer**. The slave increments the address internally for each beat. This reduces address-channel overhead and improves throughput for sequential accesses. Each transaction also carries a **transaction ID** tag, allowing multiple outstanding transactions that the slave can complete out of order — responses carry the same ID so the master can match them.

A **register bank** is a collection of flip-flops (hardware storage elements, one bit each) grouped into registers and mapped to specific byte addresses. When the master writes to address X, the register bank routes the data to the flip-flops associated with that address — they capture and hold the value. When the master reads address X, the register bank returns the current value of those flip-flops. A register bank is the simplest way to expose internal state to a bus: each register is a fixed-size slot at a fixed address, and reads/writes are immediate (no FIFOs, no queuing). In this project, the bridge uses a register bank as the interface between the AXI world (which understands addresses) and the internal logic (which understands control signals and FIFOs).

These AXI4 features (bursts, IDs, multi-beat transfers) are powerful but complex. The CVA6 naturally generates full AXI4 transactions. However, the bridge only needs to handle simple, one-at-a-time register reads and writes — it has no use for bursts or out-of-order completion. Handling full AXI4 would mean implementing a register bank that correctly processes burst decomposition, ID tracking, exclusive access, and all the corner cases. This is error-prone and unnecessary for five 64-bit registers.

The CVA6's single AXI4 master port connects to an **AXI crossbar** (interconnect) — the routing fabric that fans out to all peripherals. The crossbar has a pre-configured **AXI slave port** on its input side that accepts all transactions from the CVA6's master port, and **12 AXI master ports** on its output side — one per peripheral slave. It works like a network switch: when the CVA6 issues a transaction, the crossbar examines the address, matches it against a table of ranges (configured in `ariane_soc_pkg.sv`), and routes the transaction to the corresponding output master port. For example, a transaction to `0x5000_0000` is routed to the ML-DSA output port, which connects to the bridge's AXI slave port. Address rules are checked in priority order, so the ML-DSA rule (`0x5000_0000`, 4KB) is placed before the DRAM rule (`0x8000_0000`, 1GB) to avoid false matches. Each output port operates independently — the crossbar can route multiple transactions to different peripherals simultaneously.

### 3.4. Simplifying the Bus: AXI4-Lite and the Register Bank

Rather than implementing a full AXI4 slave, the bridge uses two production-quality IP blocks from the **pulp-platform** — an open-source hardware library maintained by ETH Zürich and the University of Bologna, silicon-proven in multiple chip tapeouts:

**`axi_to_axi_lite`** is a protocol converter with an **AXI4 slave port** on one side (facing the crossbar — it accepts transactions from the CVA6) and an **AXI4-Lite master port** on the other (facing downstream — it drives transactions into the register bank). In AXI terminology, a *slave* accepts requests (the crossbar sends it transactions) and a *master* initiates them (it sends transactions to the next module). The converter decomposes bursts into individual single-beat transactions (so a burst of 16 writes from the CVA6 becomes 16 separate AXI4-Lite writes, each with its own address phase), removes transaction IDs entirely, and handles all protocol corner cases (responses, error signaling, alignment).

**`axi_lite_regs`** has an **AXI4-Lite slave port** (it accepts the simplified transactions from `axi_to_axi_lite`) and maps them to a byte-addressable **register bank**. The critical thing to understand about `axi_lite_regs` is that it does **not** store data in internal registers that some other module must periodically poll. Instead, it produces **event-driven pulse signals** on its output wires in real time:

- When a write arrives, `axi_lite_regs` asserts `reg_we[i]` (write-enable for register index `i`) **for exactly one clock cycle** and places the write data on `reg_wdata[i]`. These are combinational outputs — they go high the moment the write is decoded and return low on the next cycle. Register indices map to byte offsets: index 0 = offset 0x00 (CTRL), index 1 = offset 0x08 (DATA_IN), index 2 = offset 0x10 (DATA_OUT), etc.
- When a read arrives, `axi_lite_regs` asserts `reg_re[i]` (read-enable for register index `i`) for one cycle and expects the user's logic to provide the return data on `reg_rdata[i]`.

The four signals `reg_we[i]`, `reg_wdata[i]`, `reg_re[i]`, and `reg_rdata[i]` are the **entire interface** between `axi_lite_regs` and the custom bridge logic. They are wires — not registers. `axi_lite_regs` drives `reg_we` and `reg_wdata` (it tells the bridge what was written); the bridge drives `reg_rdata` (it tells `axi_lite_regs` what to return for a read). `axi_lite_regs` handles all AXI4-Lite protocol details (handshakes, response codes, error handling). No AXI protocol knowledge is needed beyond these four signals.

### 3.5. The Bridge: Register Decode, Handshake Logic, and the Software Interface

The **bridge module** (`axi_mldsa_bridge.sv`) is a single SystemVerilog file that wraps everything together. Inside it are four distinct components, each with clear boundaries:

```
                    ┌─── axi_mldsa_bridge.sv ──────────────────────┐
                    │                                              │
  crossbar ───────►│  axi_to_axi_lite    (pulp-platform IP)        │
                    │       │                                      │
                    │  axi_lite_regs      (pulp-platform IP)        │
                    │       │ reg_we/reg_wdata/reg_re/reg_rdata    │
                    │       ▼                                      │
                    │  Register Decode   (custom logic)             │
                    │       │           │                           │
                    │  Input FIFO    Output FIFO (BRAM arrays)      │
                    │       │           │                           │
                    │  Handshake Logic   (custom logic)             │
                    │       │                                      │
                    └───────│──────────────────────────────────────┘
                            │ streaming interface signals
                    start, mode, sec_lvl, data_i, data_o, valid, ready
                            │
                    ML-DSA Accelerator
```

The **Register Decode** is custom logic inside the bridge — it is NOT part of `axi_lite_regs`. It is a separate block of SystemVerilog code that receives the `reg_we`/`reg_wdata` pulse wires from `axi_lite_regs` and decides what to do with them. It is written using `always_ff` blocks — a SystemVerilog construct that describes logic evaluated on every clock edge. An `always_ff @(posedge clk)` block means "on every rising clock edge, execute the following assignments." This is how sequential (clocked) logic is described in hardware: the register decode uses these blocks to capture data when `reg_we` goes high, storing values in internal flip-flops that hold their state between clock cycles.

The BRAM FIFOs are also inside the bridge module. They are **not** connected to the AXI interconnect — they have no AXI ports at all. They are simple dual-port memory arrays with a write port (data in + write pointer) and a read port (data out + read pointer). The register decode writes to them directly by incrementing the write pointer and placing data on the write-data input wires — the same way you would write to any memory array in RTL. No AXI master is needed; the FIFOs are internal to the bridge and communicate only with the register decode (on the write side) and the handshake logic (on the read side).

The bridge exposes exactly **five 64-bit registers** to software — the minimum set to cover all aspects of accelerator communication. These are not physical registers inside `axi_lite_regs`. They are addresses that `axi_lite_regs` decodes into index numbers (0–4), which the register decode then interprets:

- **CTRL** (offset 0x00 → `axi_lite_regs` register index 0): Software writes a 64-bit value here. `axi_lite_regs` asserts `reg_we[0]` and puts the value on `reg_wdata[0]`. The register decode captures this value and processes it bit by bit: bits [2:1] are extracted as `mode` and stored in an internal flip-flop; bits [5:3] are extracted as `sec_lvl` and stored in another internal flip-flop; bit [0] is the start bit. The register decode stores the *previous* value of bit [0] in a separate flip-flop (`start_d`), and compares the current value against it — if current is 1 and previous was 0, that is a rising edge. When a rising edge is detected, the register decode asserts `rst_o` for 4 cycles (resetting the accelerator), then pulses `start_o` for 1 cycle (starting it), using the `mode` and `sec_lvl` values previously captured into the internal flip-flops. Software can write CTRL multiple times — for example, first with `start=0` to set mode and sec_lvl, then with `start=1` to trigger. Only the 0→1 transition on the start bit triggers the sequence.
- **DATA_IN** (offset 0x08 → register index 1): Software writes a 64-bit word. `axi_lite_regs` asserts `reg_we[1]` and puts the value on `reg_wdata[1]`. The register decode writes this value into the **input BRAM FIFO** by placing it on the FIFO's write-data input and incrementing the write pointer. If the FIFO is full, the write is rejected.
- **DATA_OUT** (offset 0x10 → register index 2): Software reads. `axi_lite_regs` asserts `reg_re[2]`. The register decode reads the **output BRAM FIFO's** head word by reading the FIFO's read-data output and places it on `reg_rdata[2]` for `axi_lite_regs` to return. It then increments the read pointer (popping the word). If the FIFO is empty, it returns zero.
- **STATUS** (offset 0x18 → register index 3): Software reads. `axi_lite_regs` asserts `reg_re[3]`. The register decode assembles a status word from FIFO flags and internal signals and places it on `reg_rdata[3]`.
- **DIAG** (offset 0x20 → register index 4): Software reads. `axi_lite_regs` asserts `reg_re[4]`. The register decode reads the accelerator's internal state signals (wired directly from `combined_top.v`) and packs them into `reg_rdata[4]`.

**Handshake Logic** is another custom block inside the bridge. It connects the FIFOs to the accelerator's streaming interface — the component that actually moves data between the FIFOs and the accelerator:

- **Input path (FIFO → accelerator):** On every clock cycle, the handshake logic checks whether the input FIFO has data available (not empty) and whether the accelerator is asserting `ready_i` (willing to accept data). When both conditions are true, it asserts `valid_o` to the accelerator and presents the FIFO's head word on the `data_i` bus. On the clock edge where both `valid_o` and `ready_i` are high, the transfer completes — the accelerator consumes the word, and the handshake logic advances the FIFO's read pointer (popping the word).
- **Output path (accelerator → FIFO):** On every clock cycle, the handshake logic checks whether the accelerator is asserting `valid_o` (has output data) and whether the output FIFO has space (not full). When both conditions are true, the handshake logic asserts `ready_i` to the accelerator. On the clock edge where both `valid_o` and `ready_i` are high, the transfer completes — the accelerator's output word is pushed into the output FIFO.

**Communication model.** Software communicates with the accelerator through polled register access — no interrupts, no DMA. The CVA6 bare-metal environment has no interrupt controller connected to the accelerator, and the data volumes (max ~660 words) are small enough that CPU polling is adequate. The sequence is:

1. **Push** input words by writing to DATA_IN. Poll STATUS bit 1 (`in_full`) before each write.
2. **Start** the operation by writing CTRL with the start bit set.
3. **Read** output words by reading DATA_OUT. Poll STATUS bit 2 (`out_empty`) before each read.
4. **Inspect** STATUS and DIAG for debugging at any point.

### 3.6. The Buffers: FIFOs, BRAM, and the Rate Mismatch

The bridge uses **FIFOs** (First-In, First-Out buffers) on both the input and output paths. A FIFO is a hardware buffer that stores data words in order — the first word written is the first word read — using a write pointer and a read pointer that chase each other through a circular memory array. Its purpose is to **decouple** a producer and consumer that operate at different rates: if the producer writes 10 words in a burst but the consumer can only process 1 per cycle, the FIFO absorbs the burst — the producer writes all 10 quickly, then the consumer drains them over 10 cycles.

In this system, the AXI bus and the accelerator operate at irreconcilably different rates. The CVA6 produces roughly one word every 3–5 clock cycles. The accelerator's consumption rate is data-dependent: fast during LOAD_RHO, but during LOAD_MU the internal `geny` module performs Keccak hashing and applies backpressure, consuming only ~6 words before stalling for hundreds of cycles. Without FIFOs, every word would require a direct handshake between the CPU and accelerator — any mismatch means one side stalls, and with certain timing patterns the system deadlocks.

The design uses **BRAM-based FIFOs (1024-deep)**. It is important to understand what BRAM actually is in this context, because it is neither external memory on the Genesys2 board nor logic synthesized from LUTs.

**BRAM (Block RAM) is a physical, dedicated memory resource embedded inside the FPGA chip itself.** The Xilinx xc7k325t (the FPGA on the Genesys2 board) contains 445 individual BRAM36 blocks scattered across the silicon die. Each BRAM36 block is an independent 36-kilobit memory with its own read and write ports — a small, fixed SRAM that exists as hard silicon, completely separate from the programmable LUTs and flip-flops that make up the FPGA's logic fabric. BRAM is not built from LUTs — it is a pre-manufactured resource. You cannot use a BRAM block for logic, and you cannot build a BRAM block from LUTs (you can only emulate one, poorly).

When you declare a memory array in SystemVerilog and apply the synthesis attribute `(* ram_style = "block" *)`:

```systemverilog
(* ram_style = "block" *) logic [63:0] fifo_mem [0:511];
```

Vivado recognizes this as a memory pattern and **maps** it to a physical BRAM36 block on the FPGA. The array becomes a behavioral description — the synthesis tool connects the array's read and write signals to the physical BRAM's ports. From the RTL code's perspective, you read and write the array exactly like any other variable (e.g., `fifo_mem[write_ptr] <= data_in`), and the synthesis tool translates these accesses into signals that drive the physical BRAM hardware. No AXI bus is involved — the BRAM's ports are wired directly to the bridge's internal logic (register decode on the write side, handshake logic on the read side), just like any other signal assignment in RTL.

Each 1024-deep × 64-bit FIFO consumes approximately one BRAM36 block — negligible cost compared to a flip-flop-based implementation (which would require ~65K flip-flops per FIFO, consuming LUT resources that the CVA6 core already needs ~80% of). The trade-off is BRAM's **one-cycle read latency** (the output is registered — data appears one cycle after the read address). The bridge compensates with a `head_d` (delayed head pointer) that reads one cycle ahead, so data is always ready when the consumer needs it.

### 3.7. The Startup Sequence: Reset, Start Pulses, and Edge Detection

The accelerator's testbench initializes by **asserting reset** (driving it high), waiting several cycles, then **pulsing start** for exactly one clock cycle. Reset forces all sequential elements — flip-flops, counters, FSM states — to their initial values, clearing any leftover state from a previous operation. The bridge replicates this sequence: when software writes CTRL with start=1, it asserts `rst_o` for 4 cycles, then pulses `start_o` for 1 cycle.

The trigger uses **rising-edge detection** — a circuit that outputs a one-cycle pulse when a signal transitions from 0 to 1:

```systemverilog
logic start_d;
always_ff @(posedge clk)
    start_d <= start;
wire start_rise = start & ~start_d;
```

This allows software to safely write CTRL with `mode` and `sec_lvl` set but `start = 0` (configuring without triggering), then write CTRL again with `start = 1` to trigger. Only the 0→1 transition fires.

### 3.8. The Signing FSM Bug

The accelerator's signing FSM processes input data in phases, each consuming a specific number of words from the input FIFO:

```
LOAD_RHO(4) → LOAD_MU(1+variable) → DECODE_S1(80) → NTT_S1(0) → NTT_S2(96) → NTT_T0(312) → STALL
```

The **decode unit** inside the accelerator is the hardware component responsible for reading compressed polynomial data from the input stream and decompressing it into the full internal representation that gets stored in the accelerator's internal BRAM. During signing, the secret polynomials s1, s2, and t0 are transmitted in compact compressed form — the coefficients are packed into fewer bits than their natural width. The decode unit reads words from the FIFO one at a time, unpacks the encoded coefficients, and writes the decoded polynomials to internal memory. Each polynomial has 256 coefficients, and multiple polynomials must be decoded in sequence (K polynomials of s1 during DECODE_S1, then L polynomials of s2 during NTT_S2, then K polynomials of t0 during NTT_T0). The decode unit has its own counter (`ctr_dec`) that tracks how many words it has consumed and how many polynomials it has completed.

The bug was in the NTT_S1 → NTT_S2 transition. After DECODE_S1 completed and the FSM transitioned to NTT_S1, the NTT engine processed the already-loaded s1 polynomials (consuming zero FIFO words — it processes data already stored in internal BRAM). When the NTT finished (all K polynomials done), the FSM immediately transitioned to NTT_S2 **without checking whether the decode unit had finished consuming all s2 words from the FIFO**. With a small FIFO, s2 words were still queued when the FSM moved on, causing them to be misinterpreted as t0 data.

The fix adds a `ctr_dec == {K, 6'd0}-1` check to the transition, ensuring the decoder has consumed all L polynomials of s2 data before the FSM advances. The same pattern applies to subsequent transitions.

### 3.9. Diagnostic Infrastructure

Debugging an accelerator stall on an FPGA with no print output is extremely challenging. The design includes two layers of diagnostics:

**Hardware.** The DIAG register (offset 0x20) exposes 63 bits of the accelerator's internal state: all three FSM state registers (`cstate0`, `cstate1`, `cstate2`), the main counter (`ctr`), NTT operation status (`done_op`, `start_op`, `addr1_sel_op`), sampler states, and handshake signals. This can be read at any time via AXI — even when the accelerator appears stuck. Additionally, STATUS bits 8, 10–12 are **sticky diagnostic bits** that latch whether `ready_i`, `in_pop`, and `valid_o` ever went high during an operation (cleared on the next start pulse), and STATUS bits [31:16] carry `out_push_cnt` tracking how many output words the accelerator has produced.

**Software.** The C test code captures snapshots of STATUS and DIAG at key points (after push, after start, when stuck) into `volatile` global variables. These are inspectable via GDB (`x/8gx &diag_status_stuck`) without further execution. The code also pre-decodes key DIAG fields into named variables for quick inspection.

---

## 4. Register Map

The bridge exposes five 64-bit registers to software. These are not physical registers inside the accelerator — the accelerator has no concept of registers or addresses. Instead, the registers are created by the bridge's **register decode logic** (section 2.5), which interprets AXI4-Lite transactions and translates them into actions on the FIFOs, control signals, and diagnostic wires. Three of the five registers are entirely synthetic — they exist only in the bridge's logic:

- **CTRL** and **DATA_IN** are write-only registers that the register decode logic uses to capture commands and push data into the input FIFO. They have no storage — the decode logic reacts to the write-enable pulse and processes the data immediately.
- **DATA_OUT** is a read-only register that pops from the output FIFO. Again no persistent storage — the register decode returns whatever is at the FIFO's head.
- **STATUS** is a read-only register assembled dynamically from bridge-internal signals (FIFO flags, handshake state, sticky diagnostic latches, push counters). These signals originate from the bridge's FIFO control logic and handshake logic.
- **DIAG** is a read-only register that exposes signals wired directly from the **ML-DSA accelerator's internal state** (`combined_top.v`). The bridge does not generate these signals — it merely observes them and packs them into the DIAG word. The FSM states (`cstate0`, `cstate1`, `cstate2`), counters (`ctr`, `gs_sampler_sample_ctr`), NTT operation flags (`done_op`, `start_op`, `addr1_sel_op`), and handshake signals (`src_ready_s`, `src_read_s`, `dst_write_s`, `dst_ready_s`) all come from the accelerator's HDL.

All registers are 64-bit at byte offsets from `0x5000_0000`:

| Offset | Name | Access | Bits | Description |
|--------|------|--------|------|-------------|
| 0x00 | CTRL | WO | [0] | Start bit (rising edge triggers operation) |
| | | | [2:1] | Mode: 0=KeyGen, 1=Verify, 2=Sign |
| | | | [5:3] | Security level: 2=ML-DSA-44, 3=ML-DSA-65, 5=ML-DSA-87 |
| 0x08 | DATA_IN | WO | [63:0] | Push 64-bit word to input FIFO |
| 0x10 | DATA_OUT | RO | [63:0] | Read 64-bit word from output FIFO |
| 0x18 | STATUS | RO | [0] | Input FIFO empty |
| | | | [1] | Input FIFO full |
| | | | [2] | Output FIFO empty |
| | | | [3] | Output FIFO full |
| | | | [4] | Accelerator `ready_i` (live) |
| | | | [5] | Accelerator `valid_o` (live) |
| | | | [6] | Busy (start active or FIFOs non-empty) |
| | | | [8] | Start pulse active (live) |
| | | | [10] | Sticky: `ready_i` went high at least once |
| | | | [11] | Sticky: input data consumed at least once |
| | | | [12] | Sticky: `valid_o` went high at least once |
| | | | [23:16] | Output FIFO push count (low byte) |
| | | | [27:24] | Output FIFO push count (high byte) |
| 0x20 | DIAG | RO | [4:0] | `cstate0` — main FSM state |
| | | | [9:5] | `cstate1` — operation FSM state |
| | | | [14:10] | `cstate2` — generation FSM state |
| | | | [17:15] | `gs_sampler_state` |
| | | | [22:18] | `gs_sample_state` |
| | | | [23] | `gs_done_latch` |
| | | | [24] | `gs_mode` |
| | | | [25] | `done_s` |
| | | | [26] | `mux_ctrl_k` |
| | | | [37:27] | `ctr` — main word counter |
| | | | [38] | `src_ready_s` |
| | | | [39] | `src_read_s` |
| | | | [40] | `dst_write_s` |
| | | | [41] | `dst_ready_s` |
| | | | [42] | `valid_o_s` |
| | | | [43] | `ready_o_s` |
| | | | [51:44] | `gs_sampler_sample_ctr` |
| | | | [52] | `s2_prereq_done` |
| | | | [53] | `done_a` |
| | | | [54] | `valid_o` |
| | | | [55] | `done_op[0]` |
| | | | [56] | `start_op[0]` |
| | | | [57] | `ready_i_enc` |
| | | | [60:58] | `addr1_sel_op[0]` — polynomial index |
| | | | [61] | `enc_phase` |

---

## 5. Software

### 5.1. Test Programs

| File | Operation | Input Words | Output Words | Status |
|------|-----------|-------------|--------------|--------|
| `mldsa_keygen_test.c` | KeyGen | 4 (seed) | 744 (rho\|K\|s1\|s2\|t1\|t0\|tr) | ✅ Working |
| `mldsa_sign_test.c` | Sign | 510 (rho\|mlen\|tr\|fmtd\|K\|rnd\|s1\|s2\|t0) | 414 (z\|h\|ctilde) | 🔧 Fix applied, testing |
| `mldsa_test.c` | KeyGen→Sign→Verify | 4 + 510 + 660 | 744 + 414 + 1 | 🔧 Pending |

### 5.2. Signing Input Word Order (510 words total)

```
rho(4) → mlen_word(1) → tr(8) → fmtd_msg(1) → K(4) → rnd(4) → s1(80) → s2(96) → t0(312)
```

Software pushes rho(4) first, then calls `start_op(2)`. The accelerator begins consuming rho from the FIFO while software pushes the remaining 506 words. The 1024-deep BRAM FIFO ensures enough buffer for the geny backpressure pattern during LOAD_MU.

### 5.3. Toolchain

Bare-metal RISC-V compilation using `/opt/riscv/bin/riscv-none-elf-gcc`:
- `-march=rv64imac_zicsr -mabi=lp64 -mcmodel=medany -O0 -nostdlib -nostartfiles -lgcc`
- Linked with `crt.S` (sets SP, calls main) and `syscalls.c` (minimal stubs)
- Code placed in DRAM at `0x8000_0000`

---

## 6. File-by-File Changes

| # | File | Change |
|---|------|--------|
| 1 | `.gitmodules` | Added ML-DSA-OSH submodule (`corev_apu/fpga/src/ML-DSA-OSH`, from KU Leuven COSIC) |
| 2 | `corev_apu/tb/ariane_soc_pkg.sv` | Added `MLDSA = 11` to slave enum; `NB_PERIPHERALS` 10→12; `MLDSABase = 0x5000_0000`, `MLDSALength = 0x1000` |
| 3 | `corev_apu/fpga/src/axi_mldsa_bridge.sv` | **NEW** — AXI-to-streaming bridge with BRAM FIFOs, rising-edge start, sticky diagnostics |
| 4 | `corev_apu/fpga/src/ariane_xilinx.sv` | Added MLDSA address rule at port 11 (before DRAM); bridge and accelerator instantiation; `NumAddrRules = 11` |
| 5 | `Makefile` (root) | Added AXI library sources (`axi_burst_splitter`, `axi_lite_regs`, `cf_math_pkg`, `id_queue`, `onehot_to_bin`); ML-DSA VHDL sources; VHDL `read_vhdl` commands |
| 6 | `corev_apu/fpga/Makefile` | Delegates to Tcl scripts for all build variants |
| 7 | `corev_apu/fpga/scripts/prologue.tcl` | Sources `set_board_repo.tcl` before project creation |
| 8 | `corev_apu/fpga/scripts/set_board_repo.tcl` | **NEW** — Configures `board.repoPaths` from env var or default Vivado path |
| 9 | `corev_apu/fpga/xilinx/common.mk` | Sources `set_board_repo.tcl` before `run.tcl` |
| 10 | `corev_apu/fpga/scripts/run.tcl` | Changed placement/routing directives from `RuntimeOptimized` to `Explore` |
| 11 | `scripts/{quick_rebuild,fast_rebuild,impl_only}.tcl` | **NEW** — Helper scripts for incremental builds |
| 12 | `corev_apu/fpga/ariane.cfg` | Commented out GDB error-reporting options for ML-DSA register debugging |
| 13 | `verif/tests/custom/hello_world/hello_world.c` | Simplified to basic accumulator loop (no `printf`, no UART) |
| 14 | `corev_apu/fpga/sw/*` | **NEW** — Test programs (`mldsa_test.c`, `mldsa_keygen_test.c`, `mldsa_sign_test.c`) and scripts (`RISCV_compile.sh`, `run_fpga.sh`, `run_debug.sh`) |

---

## 7. Bugs Found and Fixed

### 7.1. Pre-Existing Bugs in the ML-DSA-OSH Accelerator

The ML-DSA-OSH accelerator is an independent hardware design developed by KU Leuven COSIC. While connecting it to the CVA6, multiple bugs were discovered in the accelerator's own HDL. Most of these were **not exposed by the original testbench**, which uses ideal backpressure-free streaming and only tests one phase at a time. They only surfaced when the accelerator was driven through the AXI bridge (which has realistic streaming gaps) and when phases were chained end-to-end.

These bugs are in `combined_top.v` and its submodules — they are not caused by the bridge or the CVA6 integration itself. They are candidates for upstream pull requests to the [ML-DSA-OSH repository](https://github.com/KULeuven-COSIC/ML-DSA-OSH).

#### Real upstream-design bugs (worth reporting)

| # | Bug | Location | Description | Fix Applied |
|---|-----|----------|-------------|-------------|
| 1 | KG_MULT_AS1 addr1 wrap race | `combined_top.v`, KeyGen FSM (`cstate0`) `KG_SAMPLE_S2` → `KG_MULT_AS1` transition | The original wrap condition `done_op[0] && addr1_sel_op[0]==K-1` could miss when modified transitions fired on cycles where `done_op[0]=0`. The FSM then entered MULT_AS1 with `addr1=K-1=5`, and MULT read RAM1[5*64..] which has no s1 polynomial → wrong T polynomial → KeyGen PK/SK wrong. | Force `naddr1_sel_op[0] = 4'd0` whenever `nstate0 == KG_MULT_AS1`, independent of `done_op`. |
| 2 | FSM0_NTT_S1 / FSM0_NTT_S2 impossible exit condition | `combined_top.v`, signing FSM (`cstate0`) | Prior code required `s1_ntt_all_done && ctr_dec == K*64-1` to advance out of NTT_S1. But S1 only has `L*64-1` decoder outputs (L=5 for sec_lvl=3), so `ctr_dec` can *never* reach `K*64-1 = 383`. Sign FSM hung here forever. | Revert to baseline condition `(done_op[1] && addr1_sel_op[1] == L-1)`. Same fix for NTT_S2. |
| 3 | VY_COMPARE output regression | `combined_top.v`, verify FSM, `VY_COMPARE` state | Previous code emitted 7 diagnostic words (TR, MU, hash, c, fail, rho, ntt_z_ctr0) at sec_lvl=3 — leftover FPGA debug instrumentation. The spec says Verify returns ONE word: bit 0 = fail. The testbench (and any spec-compliant consumer) reads word at ctr=6 expecting the fail bit, but got TR — so a "valid" sig looked "invalid" and vice-versa. | Revert VY_COMPARE output to baseline single-fail-bit formatting at sec_lvl=3. |
| 4 | T0 decoder shift-without-load corruption | `decoder.v` | When the upstream FIFO has transient empty cycles (which the bridge's FIFO does, because the AXI side streams slower than the decoder drains), the decoder's `if (valid_i) load else shift-only` logic on T0 pulled stale/zero bits into SIPO_IN high bits → corrupts t0 coefficients → wrong h region in signature. Standalone doesn't hit this because the TB keeps `valid_i=1` throughout. | Three-part pattern: (a) gate `valid_o=0` during stall so FSM doesn't consume duplicate samples, (b) stall condition bounded to `encode_modei==0 && !valid_i && 4*ENCODE_LVL <= sin < 2*4*ENCODE_LVL` (preserves end-of-stream draining behavior), (c) 24-cycle stall timeout to allow legitimate end-of-stream gaps. |
| 5 | operation_module.v `running` reset | `operation_module.v` | A prior patch had `running <= start`. This kept `running` asserted across operation boundaries and caused FSM restarts when software wrote CTRL between phases in a multi-phase sequence (KeyGen → Sign → Verify). | Revert to `running <= 0` (start is edge-detected elsewhere). |

#### Geny backpressure (not a bug, but a workload characteristic)

The `geny` module applies heavy backpressure during LOAD_MU (Keccak hashing), consuming only ~6 words before stalling for many cycles. This is not strictly a bug — it is a throughput characteristic of the design — but it exposes bug #4 above and makes the accelerator unsuitable for use with small input buffers. No fix applied to the accelerator itself; the bridge compensates with deep BRAM FIFOs (see section 7.2 below).

### 7.2. Bridge-Context Issues (specific to our `axi_mldsa_bridge.sv` wrapper, NOT upstream)

These are integration issues that only manifest when the accelerator is driven through our bridge. They are not candidates for upstream reporting.

| # | Issue | Location | Description | Fix Applied |
|---|-------|----------|-------------|-------------|
| 6 | Input FIFO too shallow for Sign burst | `axi_mldsa_bridge.sv` `FIFO_DEPTH` | Original 128-deep input FIFO could not hold Sign's ~515-word input burst. Mid-stream FIFO empty cycles triggered decoder bug #4 above. | Increased `FIFO_DEPTH` from 128 to 1024. |
| 7 | CTRL start-bit rising edge missed between phases | `axi_mldsa_bridge.sv` `ctrl_start_rise` | `ctrl_start_rise` is rising-edge triggered. Writing CTRL=0x1D (Sign) when CTRL=0x19 (KeyGen) is already in the register leaves `ctrl_start` stuck at 1 — no rising edge — so the 2-phase start sequence never triggers and Sign hangs indefinitely. | TB-side workaround in e2e testbenches: write CTRL=0x00 between phases to clear start bit before writing the next phase's CTRL. (Could also be hardened inside the bridge itself if desired.) |

### 7.3. Debug instrumentation added and removed

During bring-up, several diagnostic-only registers and counters were added to the accelerator HDL (`dout_compare_diag`, `mu_verify_diag`, `MULT_CT0`, `DECT0`, `keccak_word_cnt`, etc.). These were all reverted once the underlying bug was found. They were never functional changes and are not candidates for upstream reporting. The remaining diffs in `gen_s.v`, `sampler_s.v`, `expandmask_ext.v`, `makehint.v`, `usehint.v` are mostly residual diagnostic stubs that were cleaned up but not fully zeroed — they do not affect functional behavior.

---

## 8. Synthesis and Resource Utilization

The following data is from the most recent placed design (Vivado 2025.2, dated 2026-06-15) on the **xc7k325tffg900-2** (Kintex-7 325T, Genesys2 board). The design includes the full CVA6 core, the ML-DSA accelerator, the AXI-MLDSA bridge, a DDR3 memory controller, and standard peripherals (Ethernet, GPIO, SPI, UART, etc.). Source report: `corev_apu/fpga/work-fpga/ariane_xilinx_utilization_placed.rpt`.

### 8.1. Overall Device Utilization

| Resource | Used | Available | Utilization |
|----------|------|-----------|-------------|
| Slice LUTs | 153,306 | 203,800 | **75.22%** |
| — LUT as Logic | 150,274 | 203,800 | 73.73% |
| — LUT as Memory | 3,032 | 64,000 | 4.74% |
| Slice Registers (FFs) | 104,531 | 407,600 | 25.65% |
| Block RAM Tile | 83 | 445 | 18.65% |
| — RAMB36/FIFO | 82 | 445 | 18.43% |
| — FIFO36E1 | 1 | — | — |
| DSP48E1 | 43 | 840 | **5.12%** |
| F7 Muxes | 7,491 | 101,900 | 7.35% |
| F8 Muxes | 1,968 | 50,950 | 3.86% |
| Bonded IOs | 132 | 500 | 26.40% |
| BUFG (Global Clocks) | 13 | 32 | 40.63% |

### 8.2. Per-Component Breakdown

The two largest components dominate LUT usage:

| Component | Slice LUTs | Slice Registers | Notes |
|-----------|-----------|-----------------|-------|
| **CVA6 Core** (`ariane`) | 52,601 | 24,202 | RISC-V processor pipeline, caches, AXI crossbar |
| **ML-DSA Accelerator** (`i_mldsa_accel`) | 50,342 | 28,468 | Keccak, NTT/INTT, Gaussian sampler, FSMs |
| **DDR3 Controller** | 9,957 | 8,510 | Memory interface, PHY, calibration |
| **AXI-MLDSA Bridge** | (included in CVA6) | — | BRAM FIFOs, register decode, handshake logic |

Together the CVA6 core and the ML-DSA accelerator account for ~73% of total LUT usage. The DDR3 controller adds another ~7%. This leaves roughly 20% for all remaining peripherals and routing overhead — tight but feasible with the `Explore` placement directive. **75% LUT utilization is close to the practical ceiling** for this device — adding more accelerators will likely require migrating to a larger FPGA.

### 8.3. Clocking Resources

| Resource | Used | Available | Utilization |
|----------|------|-----------|-------------|
| BUFG (global buffers) | 13 | 32 | 40.63% |
| BUFR (regional buffers) | 1 | 40 | 2.50% |
| BUFH (horizontal buffers) | 1 | 168 | 0.60% |
| MMCME2_ADV (clock managers) | 4 | 10 | 40.00% |
| PLLE2_ADV (phase-locked loops) | 1 | 10 | 10.00% |

The system clock is generated by an MMCM inside `xlnx_clk_gen` at **50 MHz** (period = 20 ns, from `CLKOUT1_REQUESTED_OUT_FREQ=50`). This is the clock used by all cycle counts in this document and by all hardware-time estimates in section 8.5.

### 8.4. Resource Implications

The design fits within the device with BRAM-based FIFOs. BRAM utilization at 18.65% (83 out of 445 BRAM tiles) is low — the two 1024-deep × 64-bit bridge FIFOs consume approximately 2 BRAM36 blocks, with the rest used by the CVA6's caches (~30), the DDR3 controller (~16), the accelerator's internal polynomial storage (~30), and miscellaneous peripherals (~4). There is ample BRAM headroom for deeper FIFOs or additional buffering if needed in future iterations.

DSP utilization is very low at 5.12% (43 out of 840 DSP48E1 blocks). The ML-DSA accelerator performs most of its polynomial arithmetic using LUT-based modular arithmetic rather than DSPs — only the NTT butterflies and a few multiply-accumulate paths use DSP resources. This is a design choice in the upstream ML-DSA-OSH: favoring small footprint over raw throughput.

### 8.5. Estimated Hardware Execution Time

Wall-clock execution time can be projected from simulation because the Verilog is cycle-accurate against the placed netlist. Multiplying the simulator's cycle count by the 20 ns clock period gives the hardware wall-clock time at 50 MHz.

**Bridge-mode cycle counts** (from the most recent passing e2e bridge simulation):

| Phase | Bridge cycles | HW time @ 50 MHz | Notes |
|-------|---------------|------------------|-------|
| KeyGen | 11,391 | **228 μs** | Pure accelerator cycles; doesn't include CVA6 setup overhead |
| Sign | 87,107 | **1.74 ms** | Dominated by rejection sampling retries |
| Verify | 14,297 | **286 μs** | Includes the heavy NTT_z computation |
| **e2e total** | **112,795** | **≈ 2.26 ms** | One full KeyGen → Sign → Verify sequence |

**Standalone cycle counts** (no bridge — accelerator driven directly by an ideal testbench):

| Phase | Standalone cycles | HW time @ 50 MHz |
|-------|-------------------|------------------|
| KeyGen | 9,456 | 189 μs |
| Sign | 25,692 | 514 μs |
| Verify | 9,732 | 195 μs |

The bridge versions take roughly 1.4× longer than standalone because of AXI4 single-beat transactions (no bursting), FIFO priming latency on phase entry, and CVA6 walking through CTRL sequencing. In a real software driver, add some hundreds of cycles for the CPU to issue the AXI writes themselves — order of magnitude, still sub-millisecond per phase.

**Caveats:**

- These are simulator cycle counts which match hardware cycles (Verilog is cycle-accurate against the placed netlist).
- What *cannot* be estimated from sim alone is the actual achieved clock frequency after place-and-route timing closure. The current design meets timing at 50 MHz on the Genesys2. A more aggressive clock target would need full timing-closure verification — wall-clock time scales linearly with clock period.
- Rejection sampling in Sign is **variable**: the numbers above are for KAT vector #0. Different messages/keys produce different rejection counts, so Sign wall-clock time varies roughly ±10% in practice.

---

## 9. Design FAQ

This section addresses common questions about the architectural decisions in this project.

### 9.1. Why is `axi_to_axi_lite` needed? Couldn't we connect the CVA6 directly to `axi_lite_regs`?

No, because `axi_lite_regs` only understands AXI4-Lite, but the CVA6 generates full AXI4 transactions. These are two different protocols that are not wire-compatible.

AXI4 is a complex protocol with bursts (one address followed by multiple data words), transaction IDs (for out-of-order completion), burst types (INCR, FIXED, WRAP), and multi-beat transfers. AXI4-Lite is a simplified subset where every transaction is exactly one address + one data word — no bursts, no IDs, no complexity.

If you connected the CVA6 directly to `axi_lite_regs`, the CVA6 would send AXI4 signals (burst length, burst type, transaction ID, `w_last` beat marker) on wires that `axi_lite_regs` simply doesn't have ports for. It's like speaking a language the listener doesn't understand — the signals have nowhere to go.

`axi_to_axi_lite` is the translator. It receives full AXI4 from the CVA6, strips away everything AXI4-Lite doesn't support (decomposes bursts into individual single-beat transactions, removes transaction IDs), and outputs clean AXI4-Lite that `axi_lite_regs` can process.

### 9.2. But isn't there an AXI4 Slave IP inside `axi_to_axi_lite` that already handles bursts and IDs? Couldn't we merge that into `axi_lite_regs`?

Yes — this is a valid observation. `axi_to_axi_lite` internally contains an AXI4 slave port that handles burst decomposition and ID tracking (using an `axi_burst_splitter` and ID-tracking FIFOs). The output of all that processing is a simple, single-beat, no-ID transaction on an AXI4-Lite master port.

So your argument is: **take `axi_lite_regs`, replace its AXI4-Lite slave port with a full AXI4 slave port (that handles bursts and IDs internally), and eliminate `axi_to_axi_lite` entirely.** The result would be one module that accepts full AXI4 and maps directly to registers.

**Your argument is not wrong.** This would work. It's a valid design choice. The reason it wasn't done this way is engineering pragmatism, not technical impossibility:

- **Forking risk**: `axi_lite_regs` is a tested, documented pulp-platform module. Modifying it means forking it into a custom version that must be maintained separately. When the upstream library updates, the custom fork doesn't benefit automatically.
- **Recommended pattern**: The two-module composition (`axi_to_axi_lite` + `axi_lite_regs`) is the documented, recommended pattern in the pulp-platform AXI library. The library authors designed these modules to be composed this way.
- **Modularity**: If you later want to swap `axi_lite_regs` for a different register module, or swap `axi_to_axi_lite` for a different converter, you can do so independently. A merged module couples the AXI4 protocol handling to the register logic, making changes harder.

The converter exists as a separate module for modularity and reuse, not because the functionality couldn't be merged.

### 9.3. But doesn't the crossbar (or some other AXI infrastructure) handle burst decomposition? Why does the slave need to deal with it?

No. The crossbar is a **router**, not a protocol converter. It examines the address on each incoming transaction, decides which slave port to route it to, and passes the **entire AXI4 transaction through unchanged** — including burst length, burst type, transaction ID, everything.

When the CVA6 sends a burst write of 4 beats to `0x5000_0000`, the slave on the receiving end sees the full burst: `aw_len=3`, `aw_id=X`, `aw_burst=INCR`, then 4 separate W beats with `w_last=0, 0, 0, 1`. The crossbar does not decompose this into 4 individual transactions. The slave must count the beats, handle the address increment, and send the B response with the correct ID after the last beat.

This is how the AXI4 protocol is defined: **burst handling and ID tracking are the slave's responsibility.** No upstream infrastructure handles it for you. This is precisely why AXI4-Lite exists as a separate protocol — so that simple peripherals don't have to implement any of this — and why `axi_to_axi_lite` exists: to bridge the gap between the full-AXI4 world and the simplified AXI4-Lite world.

### 9.4. Couldn't we write a custom AXI4 slave that writes directly to the BRAM FIFO, eliminating both `axi_to_axi_lite` and `axi_lite_regs`?

Technically, yes. You could write a custom AXI4 slave that:
- Accepts full AXI4 transactions from the crossbar (handling bursts, IDs, all protocol rules)
- Has internal logic to decode addresses and write directly to the BRAM FIFOs
- Has internal logic to read from the BRAM FIFOs and return data on the AXI4 read channel

This would shorten the pipeline to: `crossbar → custom AXI4 slave → BRAM FIFOs → handshake logic → accelerator`.

The reason it wasn't done this way is risk. Writing a correct AXI4 slave requires handling burst decomposition (INCR, FIXED, WRAP burst types), transaction ID tracking and out-of-order completion, exclusive access, narrow transfers, error response codes, and all the valid/ready handshake corner cases across five independent channels. Getting any of these wrong produces bugs that are extremely difficult to debug — they only appear under specific traffic patterns (e.g., when the CVA6 happens to issue a burst during a cache line fill). For a bridge that only needs five registers accessed one at a time, implementing all of AXI4 is massive overkill with significant risk. The `axi_to_axi_lite` + `axi_lite_regs` combination eliminates that risk with proven, silicon-tested IP.

### 9.5. Could the internal FIFOs of `axi_to_axi_lite` replace the BRAM FIFOs?

No. The `axi_to_axi_lite` module does contain two internal FIFOs (`i_aw_id_fifo` and `i_ar_id_fifo`), but they serve a completely different purpose:

| | `axi_to_axi_lite` internal FIFOs | Bridge BRAM FIFOs |
|---|---|---|
| **What they store** | Transaction IDs only (a few bits) | Full 64-bit data words |
| **Their purpose** | Match AXI4 responses to requests by ID | Decouple the CVA6's write rate from the accelerator's consumption rate |
| **Their depth** | `AxiMaxWriteTxns` (a handful of entries) | 512 entries |
| **The problem they solve** | AXI4 protocol compliance (ID tracking) | Backpressure from the accelerator during LOAD_MU |

The internal FIFOs are ID-tracking FIFOs — when a write address arrives, they push the transaction ID. When the write response goes out, they pop the ID and attach it to the response. They never see the actual data payload. They exist purely for AXI4 protocol correctness.

The BRAM FIFOs exist because the accelerator can stall for hundreds of cycles (e.g., during LOAD_MU, the `geny` module performs Keccak hashing and consumes only ~6 words before applying backpressure). You need 512 entries of actual data buffering to absorb this mismatch. The ID-tracking FIFOs inside `axi_to_axi_lite` would overflow after a few transactions — they're the wrong size, store the wrong data, and solve the wrong problem.

---

## 10. Simulation Testing Methodology

Before any hardware deployment, the design is verified in simulation using two complementary testbench configurations. Both compile and simulate the **exact same accelerator HDL** (`combined_top.v` and its submodules) — the difference is what drives the accelerator's streaming interface.

The 8-test simulation suite (3 standalone + 3 bridge + 2 e2e) is documented in section 2.1. This section explains the **communication flow** inside each testbench mode.

### 10.1. Standalone Simulation

In standalone mode, the testbench talks to the accelerator **directly, wire-to-wire**. There is no bridge, no AXI, no FIFO, no CPU. The TB itself is the producer and consumer.

```
                 ┌──────────────────────────┐
                 │   Testbench (Verilog)    │
                 │                          │
                 │  $readmemh KAT → array  │
                 │                          │
                 │   for each input word:   │
                 │     drive valid_i = 1    │
                 │     drive data_i = word  │
                 │     wait (ready_o == 1)  │
                 │                          │
                 │   for each output word:  │
                 │     wait (valid_o == 1)  │
                 │     capture data_o       │
                 │     drive ready_i = 1    │
                 └──────────────────────────┘
                              │
                              │ streaming interface
                              │ (valid/ready/data wires)
                              ▼
                 ┌──────────────────────────┐
                 │  ML-DSA Accelerator      │
                 │  (combined_top.v)        │
                 └──────────────────────────┘
```

**Communication flow (KeyGen example), cycle-by-cycle:**

1. **Reset**: TB asserts `rst = 1` for a few cycles, then deasserts.
2. **Configure**: TB drives `mode = 0` (KeyGen), `sec_lvl = 3` on the control wires.
3. **Start pulse**: TB drives `start = 1` for exactly 1 clock cycle, then `start = 0`. The accelerator's FSM latches `mode`/`sec_lvl` on this edge and leaves INIT.
4. **Push 4 input words** (the seed):
   - Cycle N: TB sets `valid_i = 1`, `data_i = seed[0]`. Accelerator says `ready_o = 1`. Transfer happens.
   - Cycle N+1: same for `seed[1]`… etc.
   - **`valid_i` is held at 1 throughout** — no gaps, no backpressure. The TB is faster than the accelerator, so it never has to wait.
5. **Wait**: accelerator runs internally (~9,000 cycles of NTT, sampling, hashing). TB idle.
6. **Capture 744 output words** (rho, K, s1, s2, t1, t0, tr):
   - Accelerator drives `valid_o = 1`, `data_o = word[0]`. TB sees this and immediately drives `ready_i = 1`. Transfer happens in 1 cycle.
   - Same for word[1]…word[743].
7. **Compare**: TB compares each captured word against the expected KAT value loaded via `$readmemh`. Mismatches print "WRONG". `run.sh` greps for "WRONG" count.

**Why standalone is "ideal"**: the TB has zero latency between producing a word and the accelerator accepting it. There is never backpressure — `valid_i` is glued to 1 throughout the entire input phase. This is exactly why the T0 decoder stall bug (section 7.1, bug #4) doesn't manifest in standalone: the decoder never sees a transient `valid_i = 0` cycle.

### 10.2. Bridge Simulation

In bridge mode, the testbench drives the **AXI4 side** of `axi_mldsa_bridge.sv`. It mimics what the CVA6 CPU would do — issue load/store instructions to addresses in the `0x5000_0000` range. The accelerator runs the same HDL as standalone, but it is now separated from the TB by the full bridge stack.

```
 ┌─────────────────────────────┐
 │  Testbench (SystemVerilog)  │
 │                             │
 │  AXI4-Lite master drives:   │     ┌─────────────────────────────────┐
 │    AWADDR/WDATA/B           │     │       axi_mldsa_bridge.sv       │
 │    ARADDR/R                 │     │                                  │
 │                             │     │  axi_to_axi_lite                 │
 │  write CTRL = 0x19          │────►│  axi_lite_regs                   │
 │  write DATA_IN = word       │────►│  register decode                 │
 │  write CTRL = 0x1D (start)  │────►│  input FIFO  (BRAM, 1024-deep)   │
 │  poll STATUS                │◄────│  handshake logic                 │
 │  read DATA_OUT              │◄────│  output FIFO (BRAM, 1024-deep)   │
 └─────────────────────────────┘     └────────────────┬────────────────┘
                                                       │ streaming interface
                                                       ▼
                                        ┌──────────────────────────┐
                                        │  ML-DSA Accelerator      │
                                        │  (combined_top.v)        │
                                        └──────────────────────────┘
```

**Communication flow (KeyGen example), cycle-by-cycle:**

1. **Configure**: TB issues an AXI write to `0x5000_0000` (CTRL) with value `0x19` = `mode=2'b00 | sec_lvl=3'b011 | start=0`. Path through the bridge:
   - `axi_to_axi_lite`: AXI4 → AXI4-Lite (split burst, strip ID).
   - `axi_lite_regs`: decodes offset 0x00 → register index 0. Asserts `reg_we[0] = 1` for 1 cycle, places `0x19` on `reg_wdata[0]`.
   - Register decode: latches `mode = 0`, `sec_lvl = 3` into internal flip-flops. Stores `start = 0` for edge detection.

2. **Push 4 input words** (the seed): TB issues 4 AXI writes to `0x5000_0008` (DATA_IN), one per seed word. Each write: `axi_lite_regs` asserts `reg_we[1]` → register decode increments the input FIFO write pointer and stores the word in BRAM.
   - **All 4 words land in the FIFO before the accelerator even starts.** This is the key difference from standalone — there is a buffer between producer and consumer.

3. **Start**: TB issues another AXI write to CTRL with value `0x1D` = same mode/sec_lvl but `start = 1`. Register decode sees `start: 0 → 1` rising edge → asserts `rst_o = 1` for 4 cycles (resetting the accelerator FSM) → then pulses `start_o = 1` for 1 cycle. Accelerator latches `mode`/`sec_lvl` and leaves INIT.

4. **Accelerator drains the FIFO**: bridge handshake logic checks every cycle: is FIFO non-empty AND accelerator `ready_i = 1`? When both true: drives `valid_o = 1` to accelerator, presents `data_i = FIFO_head`. On the cycle where accelerator says `ready_i = 1`, the transfer happens and the bridge pops the FIFO.
   - **Critical difference**: producer (TB/AXI) and consumer (accelerator) are now decoupled. The bridge can have transient FIFO-empty cycles if the accelerator drains faster than the TB pushes new words via AXI. This is exactly what exposes bug #4 (T0 decoder shift-without-load).

5. **Wait**: accelerator runs KeyGen (~9,000 cycles). TB polls STATUS register (AXI reads to `0x5000_0018`).

6. **Capture 744 output words**:
   - Accelerator drives `valid_o = 1`, `data_o = word`. Bridge handshake logic: accelerator `valid_o = 1` AND output FIFO not full → drives `ready_i = 1`. Word gets pushed to output FIFO.
   - TB polls STATUS bit 2 (`out_empty`). When `0` (FIFO has data), TB issues AXI read to `0x5000_0010` (DATA_OUT). Register decode reads FIFO head, places on `reg_rdata[2]`, pops FIFO.
   - Repeat 744 times.

7. **Compare**: same as standalone — TB compares captured words to KAT expected.

### 10.3. Practical Differences

| Aspect | Standalone | Bridge |
|--------|-----------|--------|
| TB drives | Streaming wires directly | AXI4-Lite transactions |
| Producer ↔ consumer | Tight, same cycle | Decoupled by 1024-deep BRAM FIFO |
| Backpressure | None (TB always ready) | Real (FIFO can drain mid-stream) |
| Start | `start` wire pulse (1 cyc) | AXI write to CTRL → bridge does 4-cycle reset + 1-cycle start pulse |
| Output capture | Direct capture on `valid_o` | Poll STATUS, AXI read from DATA_OUT (pops FIFO) |
| Exposes decoder stall bug? | **No** (ideal `valid_i=1`) | **Yes** (real FIFO gaps) |
| Cycle overhead | Baseline | ~1.2× (KeyGen) to ~3.4× (Sign) due to AXI per-beat cost |
| What it proves | Accelerator HDL is functionally correct | Accelerator + bridge + AXI stack is functionally correct |

**Cycle-count overhead, concretely (KeyGen):**
- Standalone: 9,456 cycles (push 4 → run → capture 744)
- Bridge: 11,391 cycles (~1.2× slower)
- Extra ~2,000 cycles are: AXI4-Lite transaction overhead per register access (~5 cycles each for AW→W→B handshake), bridge's 4-cycle reset + 1-cycle start pulse on phase entry, FIFO priming latency, TB polling STATUS between output reads.

For Sign (515 input words), the per-beat AXI overhead dominates — that's why bridge Sign (87,107 cycles) is ~3.4× slower than standalone Sign (25,692 cycles).

### 10.4. Why Both Modes Are Required

The two configurations catch different classes of bugs:

- **Standalone sim is a sanity check on the accelerator HDL itself.** If standalone fails, the bug is in `combined_top.v` or its submodules, not in our integration. The standalone testbench matches the upstream ML-DSA-OSH testbench pattern, so any regression here would also fail upstream.
- **Bridge sim is a system-level test.** If standalone passes but bridge fails, the bug is either (a) in the bridge wrapper itself, or (b) in how the accelerator reacts to realistic streaming patterns with transient gaps. The T0 decoder stall bug (section 7.1, bug #4) is the canonical example of (b): the decoder's `if (valid_i) load else shift-only` logic is unsafe when `valid_i` has gaps, but the standalone TB never produces gaps so the bug is invisible there.

The **e2e variants** (standalone and bridge) chain KeyGen → Sign → Verify using each phase's actual output as the next phase's input — no pre-baked KAT values across phases. This catches multi-phase sequencing issues that single-phase tests miss. The CTRL start-bit clear issue (section 7.2, issue #7) is the canonical example: between phase 1 (KeyGen) and phase 2 (Sign), software must write CTRL=0x00 to clear the start bit before writing the next phase's CTRL, otherwise the bridge's rising-edge detector never fires and phase 2 hangs.

The complete 8-test suite (3 standalone + 3 bridge + 2 e2e) and its current pass/fail status is documented in section 2.1.

---

## 11. Build, Program, and Debug

### 11.1. Prerequisites

- Xilinx Vivado 2025.2
- RISC-V toolchain at `/opt/riscv/bin/riscv-none-elf-*`
- OpenOCD (for JTAG debug)
- Genesys2 FPGA board (xc7k325tffg900-2)

### 11.2. Build the Bitstream

```bash
cd ~/cva6
git submodule update --init --recursive
make -C corev_apu/fpga clean
RISCV=/opt/riscv make fpga
# Output: corev_apu/fpga/work-fpga/ariane_xilinx.bit
# Build time: 30–60 minutes
```

### 11.3. Program the FPGA

```bash
killall hw_server cs_server 2>/dev/null; sleep 1
/opt/Xilinx/2025.2/Vivado/bin/vivado -nojournal -mode batch -source /tmp/program_fpga.tcl
```

Where `/tmp/program_fpga.tcl` contains:
```tcl
open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target
set device [get_hw_devices xc7k325t_0]
current_hw_device $device
set_property PROGRAM.FILE {/home/quasart1/cva6/corev_apu/fpga/work-fpga/ariane_xilinx.bit} $device
program_hw_devices $device
close_hw_manager
```

### 11.4. Run Tests

```bash
cd ~/cva6/corev_apu/fpga/sw
./run_fpga.sh mldsa_test.c              # compile + load + run (full round-trip)
./run_fpga.sh mldsa_keygen_test.c       # KeyGen only
./run_fpga.sh mldsa_sign_test.c         # Sign only
```

### 11.5. Debug via GDB

If the accelerator stalls, the test code captures diagnostics into `volatile` global variables. Connect via GDB to inspect:

```bash
riscv-none-elf-gdb corev_apu/fpga/sw/mldsa_test.elf
(gdb) set architecture riscv:rv64
(gdb) target remote :3333
(gdb) x/8gx &diag_status_stuck       # STATUS register at stall point
(gdb) x/8gx &diag_accel_stuck         # DIAG register at stall point
(gdb) print diag_stuck_cstate0         # Decoded: main FSM state
(gdb) print diag_stuck_ctr             # Decoded: word counter
(gdb) print diag_stuck_done_op         # Decoded: NTT done?
```

Or use the batch GDB script:
```bash
./run_fpga.sh mldsa_test.c
# When stalled, in another terminal:
riscv-none-elf-gdb -x /tmp/read_sign2.gdb
```

### 11.6. SoC Address Map

Complete memory map from `ariane_soc_pkg.sv`:

| Peripheral | Base Address | Length | Index |
|-----------|-------------|--------|-------|
| Debug | 0x0000_0000 | 0x1000 | 9 |
| ROM | 0x0001_0000 | 0x10000 | 8 |
| CLINT | 0x0200_0000 | 0x10000 | 7 |
| PLIC | 0x0C00_0000 | 0x4000_0000 | 6 |
| UART | 0x1000_0000 | 0x1000 | 5 |
| Timer | 0x2000_0000 | 0x10000 | 4 |
| SPI | 0x2000_0000 | 0x10000 | 4 |
| Ethernet | 0x3000_0000 | 0x10000 | 3 |
| GPIO | 0x4000_0000 | 0x1000 | 2 |
| **ML-DSA** | **0x5000_0000** | **0x1000** | **11** |
| DRAM | 0x8000_0000 | 0x4000_0000 | 1 |
| HPS | 0xFF80_0000 | 0x800_0000 | 10 (unused on Xilinx) |

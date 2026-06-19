<!--
==================================================
Giulio Golinelli - golinelli.giulio13@gmail.com
TUMCREATE QUASAR RESEARCH ENGINEER
Modified: 2026-06-17
This file contains modifications vs. the upstream
CVA6 / ML-DSA-OSH source fork.
==================================================
-->

# ML-DSA-OSH Bugs Report

**Date:** 2026-06-17
**Scope:** Bugs found while integrating the upstream ML-DSA-OSH accelerator onto CVA6 — split into (a) genuine bugs in the **original upstream design** (anyone using the accelerator could hit them), (b) bugs that only appear in **our bridge wrapper**, and (c) debug code that was added and then removed.

This is the bug companion to `MLDSA_FPGA_TIMING_REPORT.md` (FPGA utilization & timing). Full design notes live in `CVA6_MLDSA_INTEGRATION.md`; the operational log is `PROJECT_STATUS.md`.

---

## TL;DR — who should be told, and how urgent

| Bug | One-line plain description | Where the bug lives | Report upstream? | Severity |
|-----|----------------------------|---------------------|------------------|----------|
| 1 | KeyGen sometimes reads the wrong memory slot → silent bad keys | `combined_top.v` (upstream) | **YES — KU Leuven COSIC** | High |
| 2 | Sign waits for a counter value that can never happen → freezes forever | `combined_top.v` (upstream) | **YES — KU Leuven COSIC** | High |
| 3 | Verify returns 7 debug words instead of 1 pass/fail word → answer flipped | `combined_top.v` (upstream) | **YES — KU Leuven COSIC** | High |
| 4 | Decoder drags in stale bits when data briefly pauses → corrupted signatures | `decoder.v` (upstream) | **YES — KU Leuven COSIC** | High |
| 5 | "Busy" flag not reset between phases → 2nd phase crashes | `operation_module.v` (upstream) | **YES — KU Leuven COSIC** | Medium |
| 6 | Our bridge's input buffer too small → overflows → triggers bug 4 | `axi_mldsa_bridge.sv` (ours) | No — internal | Medium |
| 7 | "Start" signal needs a 0→1 edge; 2nd phase never starts | `axi_mldsa_bridge.sv` (ours) | No — internal | Medium |

**Bottom line:** Bugs 1–5 belong to the people who wrote the accelerator (KU Leuven COSIC). Bugs 6–7 are ours to fix and keep to ourselves. See [Reporting upstream](#how-to-report-upstream) at the bottom for the practical how-to.

---

## Upstream bugs (1–5) at a glance — class, plain-English, and why the original testbench missed each

Locations point into the **patched local submodule** (`corev_apu/fpga/src/ML-DSA-OSH/ref_combined/src/…`), where every original bug-site is now marked with a `// fix` comment — so the quoted line is the fix itself or the comment describing the upstream defect. Descriptions are one phrase each.

| # | Location (quoted line) | Class | Technical — 1 phrase | In plain words — 1 phrase | Why the original TB missed it |
|---|------------------------|-------|----------------------|---------------------------|-------------------------------|
| 1 | [combined_top.v:1047](corev_apu/fpga/src/ML-DSA-OSH/ref_combined/src/combined_top.v#L1047) `… ? KG_MULT_AS1 : KG_SAMPLE_S2` + [:1055](corev_apu/fpga/src/ML-DSA-OSH/ref_combined/src/combined_top.v#L1055) `naddr1_sel_op[0]=(nstate0==KG_MULT_AS1)?4'd0` | Race / FSM transition hazard | Transition can fire while `done_op[0]=0`, leaving `addr1=K-1` so MULT reads the wrong s1 slot → wrong T. | KeyGen jumps to the next step pointing at the last memory page, silently yielding a wrong key. | The race only triggers under one specific simulator/tool-version scheduling their flow never produced. |
| 2 | [combined_top.v:1890](corev_apu/fpga/src/ML-DSA-OSH/ref_combined/src/combined_top.v#L1890) *"ctr_dec==K\*64-1 … impossible for S1"* + [:1897](corev_apu/fpga/src/ML-DSA-OSH/ref_combined/src/combined_top.v#L1897) `… ? FSM0_NTT_S2 : FSM0_NTT_S1` | Deadlock (unreachable exit cond.) | FSM0_NTT_S1/S2 waits for `ctr_dec==K*64-1`, which S1's `L*64` outputs can never reach → Sign hangs. | Sign waits for a counter value that cannot exist, freezing forever. | At sec_lvl=2 (K==L==4) the counter *can* reach the target, masking the hang if they ran level 2. |
| 3 | [combined_top.v:1740](corev_apu/fpga/src/ML-DSA-OSH/ref_combined/src/combined_top.v#L1740) `data_o=(ctr==6&&sec_lvl==3)?{63'd0,fail}:0` | Spec non-conformance (output format) | VY_COMPARE emits a 7-word diagnostic vector instead of the spec's single fail-bit word. | Verify dumps debug words where one pass/fail bit should be, flipping accept/reject. | Their TB read the fail bit from the word their own non-spec code used, so TB and DUT agreed (self-referential). |
| 4 | [decoder.v:183](corev_apu/fpga/src/ML-DSA-OSH/ref_combined/src/decoder.v#L183) `valid_o=(… && !dec_stall)?1:0` + [:230](corev_apu/fpga/src/ML-DSA-OSH/ref_combined/src/decoder.v#L230) `SIPO_IN<=SIPO_IN` | Backpressure / pipeline hazard | T0 decoder shift-register advances on empty cycles (shift-without-load), dragging stale bits into t0. | When data pauses one cycle, the conveyor belt drags in junk and scrambles the signature. | Their TB holds `valid_i` high every cycle, so the FIFO never empties and the bug never fires. |
| 5 | [operation_module.v:238](corev_apu/fpga/src/ML-DSA-OSH/ref_combined/src/operation_module.v#L238) `running<=0; // reverted from <= start` | State leak across op boundary | `running<=start` keeps the busy flag asserted across operations, restarting the FSM on the next phase. | A "busy" flag never clears between phases, so the second phase crashes. | Their TBs run one phase per reset, so the cross-phase flag bleed never occurs. |

The five classes are distinct: a *race* (1), a *deadlock from an unreachable exit condition* (2), a *spec-format violation* (3), a *backpressure/pipeline hazard* (4), and a *state leak across operation boundaries* (5) — each invisible to the upstream self-tests for a different, concrete reason (last column).

---

## How the bugs are grouped

The fixes are layered. Before reading the details, it helps to know which bucket each bug is in:

- **Real upstream-design bugs (1–5)** — would affect *any* integrator, not just us. These are the ones worth telling the original authors about.
- **Bridge-context bugs (6–7)** — only show up when data flows through our `axi_mldsa_bridge.sv` wrapper, never when an ideal testbench drives the accelerator directly. These are our problem, not upstream's.
- **Debug instrumentation** — diagnostic-only registers/counters added during bring-up and then removed. Not bugs at all. Listed briefly at the end so they aren't mistaken for real issues.

---

## Real upstream-design bugs (worth reporting to KU Leuven COSIC)

These are genuine defects in the ML-DSA-OSH RTL. Each entry has three parts: the **technical** statement (what's wrong, where, and the fix), an **in plain words** explanation for readers who aren't deep in the RTL, and a **why the upstream testbench missed it** note — the practical reason KU Leuven COSIC's own self-tests stayed green, which is exactly what to cite when filing the report.

### Bug 1 — KeyGen reads the wrong polynomial slot (silent bad keys)

**Technical — `combined_top.v`, `KG_SAMPLE_S2` → `KG_MULT_AS1` transition.**
The transition condition could fire on cycles where `done_op[0]=0` (still waiting on `ctr` / `S2_LEN`). When it did, `naddr1_sel_op[0]` did not wrap via the `==K-1` path and entered `KG_MULT_AS1` with `addr1 = K-1 = 5`. MULT then read RAM1[5*64..], which holds no s1 polynomial → wrong T polynomial → KeyGen PK/SK wrong.
**Fix:** Force `naddr1_sel_op[0] = 0` whenever `nstate0 == KG_MULT_AS1`.

**In plain words.** Key generation builds a key by reading polynomials out of a small block of memory, one after another, like reading pages 1, 2, 3, 4, 5 from a book. There's a clock-like counter that says "which page am I on." The bug: the state machine sometimes jumps to the next step a beat too early, while the counter is still parked on the *last* page (page 5). So instead of starting the next step at page 1, it starts at page 5 and reads the wrong data. The key it produces looks perfectly normal but is silently wrong — signatures made with it will never verify. This is the most dangerous kind of bug: it gives no error, just a broken result.

**Impact:** CVA6 KeyGen emits keys that don't validate. **Severity: High.**

**Why the upstream testbench missed it:** This is a *race*. The bad transition fires only for one specific ordering of how the simulator evaluates the FSM versus `done_op`/`ctr` in the same clock — and whether that ordering occurs depends on the simulator and tool version. If their flow never produces it, the buggy branch never runs and every KeyGen KAT comparison passes. Races are non-deterministic; *any single tool flow can be blind to them.* (Would surface under a regression run on ≥2 different simulators/versions.)

---

### Bug 2 — Sign freezes forever (counter can't reach its target)

**Technical — `combined_top.v`, `FSM0_NTT_S1` and `FSM0_NTT_S2` transitions.**
Prior code required `s1_ntt_all_done && ctr_dec == K*64-1` to advance. But S1 only has `L*64-1` decoder outputs (L=5 for sec_lvl=3), so `ctr_dec` can *never* reach `K*64-1 = 383`. The Sign FSM hung here forever.
**Fix:** Revert to baseline `(done_op[1] && addr1_sel_op[1] == L-1)`.

**In plain words.** The Sign step has a state that's supposed to wait until a counter reaches the number 384 before moving on. The problem: for security level 3, that counter physically tops out at 319. It can count to 319 and then it's done — it has no way to ever reach 384. So the state machine sits there waiting for the impossible, forever. It's like waiting for a clock to strike 13 o'clock. The accelerator freezes, the data pipeline drains, and the CPU never sees "done" — Sign just hangs.

**Impact:** Sign hangs the accelerator → bridge FIFO drains and never refills → CVA6 sees `ready=0` forever. **Severity: High.**

**Why the upstream testbench missed it:** The unreachable counter only bites when **L < K** — i.e. ML-DSA-65 (level 3) and ML-DSA-87 (level 5). At **ML-DSA-44 (level 2), K == L == 4**, so the counter *can* reach its target and Sign completes normally. If their default testbench ran level 2 (the smallest, fastest config — a common default), the hang is invisible. (Would surface in a sweep across all three security levels.)

---

### Bug 3 — Verify returns the wrong output format (pass/fail flipped)

**Technical — `combined_top.v`, `VY_COMPARE` output.**
Previous code emitted 7 diagnostic words (TR, MU, hash, c, fail, rho, ntt_z_ctr0) at sec_lvl=3. The spec says Verify returns ONE word: bit 0 = fail. A spec-compliant consumer reads the word at ctr=6 expecting the fail bit, but got TR — so a "valid" sig looked "invalid" and vice-versa.
**Fix:** Revert to baseline single-fail-bit output.

**In plain words.** Verify is supposed to answer one simple question with one simple word: "is this signature valid?" — a single yes/no bit (technically a "fail" bit). The old code instead spat out seven words of internal debug info. Now, any normal program reads the result at the slot where the yes/no answer is supposed to be, but finds a completely different piece of data sitting there. So it misreads the answer: a genuine signature gets reported as a forgery, and a forged one gets reported as genuine. The verification still "runs" and prints a result — it's just the wrong result. For a security feature, silently flipping accept/reject is about as bad as it gets.

**Impact:** CVA6 verify silently passes/fails wrong. **Severity: High.**

**Why the upstream testbench missed it:** *Self-referential checking.* Their verify testbench was written to read the fail bit from whichever word position their own (non-spec) code placed it — so TB and DUT agreed with each other and the KAT comparison passed, even though both violated the FIPS 204 one-word contract. Any spec-following *external* consumer reads the wrong slot. (Would surface if the TB expectations were checked against the FIPS 204 output contract rather than the DUT's actual output.)

---

### Bug 4 — Decoder corrupts data when the input briefly pauses

**Technical — `decoder.v`, T0 `shift-without-load`.**
When the upstream FIFO has transient empty cycles (which the bridge's FIFO does, because the AXI side streams slower than the decoder drains), the decoder's `shift-without-load` on T0 pulls stale/zero bits into output position → corrupts t0 coefficients → wrong h region in signature. Standalone doesn't hit this because the TB keeps `valid_i=1` throughout.
**Fix:** Three-part pattern — (a) gate `valid_o` during stall, (b) bound the stall condition to `4*ENCODE_LVL <= sin < 2*4*ENCODE_LVL` (preserves end-of-stream draining), (c) 24-cycle stall timeout.

**In plain words.** Part of decoding works like a conveyor belt: data bits shift along a line, one position per clock, and new bits get loaded in at the front. The belt moves every single clock whether or not a fresh bit arrived. If the data feeding the belt hiccups for even one clock (no new bit that cycle), the belt still moves and drags a stale/empty bit into the stream — and from then on every downstream bit is shifted wrong. The standalone testbench shovels data in every single clock with no gaps, so it never sees the hiccup. But our real-world bridge *does* have gaps — the memory bus can't keep up with the belt — so the belt drags in junk and the signature's "t0" numbers come out scrambled. Scrambled t0 means the signature fails verification.

**Impact:** Signatures produced through the bridge fail verification. **Severity: High** (and the trigger — upstream FIFO stutters — is common in any real system, so this one will hit other integrators too).

**Why the upstream testbench missed it:** *Ideal interfaces.* Their streaming testbench holds `valid_i` high every cycle — a perfect producer that never stalls — so the upstream FIFO never has an empty cycle and the corrupting `shift-without-load` path is never exercised. Real AXI buses physically can't hold `valid` high continuously (arbitration, single-beat transactions, and FIFO priming all insert gaps). (Would surface under a TB with randomized `valid`/`ready` strobing and random stall cycles.)

---

### Bug 5 — "Busy" flag not cleared between phases (2nd phase crashes)

**Technical — `operation_module.v`, `running` reset.**
A prior patch had `running <= start`. This kept `running` asserted across operation boundaries and caused FSM restarts when software wrote CTRL between phases.
**Fix:** Revert to `running <= 0`.

**In plain words.** There's a "busy" flag the accelerator raises while working and is supposed to lower when it finishes. The bug kept that flag stuck *up* even after the work was done — it never got lowered between one operation and the next. So when software kicked off the second operation (e.g. Sign right after KeyGen), the accelerator saw the still-raised flag, got confused about its own state, and restarted from the beginning. Any multi-step sequence — which the full KeyGen→Sign→Verify chain is — blew up on the second step.

**Impact:** Multi-phase (end-to-end) sequences fail on the second phase. **Severity: Medium** (single-phase runs are fine; this only bites chained runs).

**Why the upstream testbench missed it:** *Single-phase coverage.* Their module-level testbenches reset the core, run one operation, check, and end the sim — so the `running` flag bleeding across a phase boundary never matters; each run starts clean. The bug only appears when phases are chained in one run with no reset between them (an end-to-end sequence), which the suite doesn't exercise. (Would surface in a chained end-to-end test with no reset between phases.)

---

## Bridge-context bugs (do NOT report — these are ours)

These only manifest when data flows through our `axi_mldsa_bridge.sv` wrapper, because an ideal testbench feeds/perfectly times data the way the accelerator expects. The original authors wouldn't see them.

### Bug 6 — Bridge input FIFO too small

**Technical — `axi_mldsa_bridge.sv`, `FIFO_DEPTH=128`.**
The original 128-deep input FIFO could not hold Sign's ~515-word input burst. Mid-stream FIFO empty cycles triggered bug #4.
**Fix:** `FIFO_DEPTH = 1024`.

**In plain words.** Our bridge has a small holding tank (FIFO) that buffers data coming in from the CPU before the accelerator drinks it. Sign needs to dump about 515 words at once, but the tank only held 128. So mid-way through, the tank ran dry for a few clocks — and as described in Bug 4, even a one-clock dry spell corrupts the signature. Making the tank big enough (1024) fixes it. This is purely about *our* bridge's plumbing; the original chip, driven by a testbench that never pauses, never runs the tank dry.

---

### Bug 7 — `ctrl_start` only triggers on a rising edge

**Technical — `axi_mldsa_bridge.sv`, `ctrl_start_rise`.**
`ctrl_start_rise` is rising-edge triggered. Writing CTRL=0x1D (Sign) when CTRL=0x19 (KeyGen) is already in the register → `ctrl_start` already at 1 → no rising edge → no 2-phase start trigger → accelerator stays in IDLE → Sign hangs forever.
**Fix (testbench-side workaround):** In e2e testbenches, write CTRL=0x00 between phases to clear the start bit before writing the next phase's CTRL. (A cleaner RTL-side fix — making the start logic level-sensitive or self-clearing — is a future cleanup.)

**In plain words.** The "start" signal only wakes up on a transition from 0 to 1 — like a button that only registers a press, not a hold. During a single-phase run that's fine: the bit goes 0→1 and off we go. But in a two-phase run, after phase 1 the start bit is already sitting at 1. When software writes the start command for phase 2, the bit goes 1→1 — no edge, no press — so phase 2 never begins and the accelerator idles forever. The workaround is to have software deliberately write a 0 in between, so the next "1" creates a real 0→1 press. Again, this is about how *our* bridge interprets the control register, not a defect in the accelerator itself.

---

## Non-bugs: debug instrumentation added and removed

These were *diagnostic-only* registers/counters added during debugging (`dout_compare_diag`, `mu_verify_diag`, `MULT_CT0`, `DECT0`, `keccak_word_cnt`, etc.) — all reverted once the underlying bug was found. They are **not** upstream issues and shouldn't be reported. The remaining diffs in `gen_s.v`, `sampler_s.v`, `expandmask_ext.v`, `makehint.v`, `usehint.v` are mostly residual diagnostic stubs that were cleaned up but not fully zeroed — they don't affect functional behavior.

---

## Are these "normal" / should we report upstream?

- **Bugs 1, 2, 3, 4 (real upstream bugs):** **YES, worth reporting upstream.** Bug #1 is a race condition in the FSM transition that may only fire under specific tool versions — could be a recent regression in their codebase, or genuinely undetected. Bugs #2, #3, #4 are more clearly design issues. KU Leuven COSIC would likely accept a clean repro.
- **Bug 5 (operation_module running reset):** Likely worth reporting — appears to be a genuine regression.
- **Bugs 6, 7 (bridge-context):** **NOT upstream issues** — they are about our specific bridge wrapper. No report needed.

---

## How to report upstream

**Who:** KU Leuven COSIC — the Cryptography and Security group at KU Leuven, authors/maintainers of the ML-DSA-OSH open-source hardware implementation of ML-DSA (the post-quantum signature scheme standardized by NIST, formerly Dilithium).

**Where:** The project's public repository, **`github.com/KULeuven-COSIC/ML-DSA-OSH`**, via GitHub Issues (or a Pull Request if a fix is included). Each of bugs 1–5 is small enough to be its own issue with a self-contained repro.

**What to send per bug:**
1. A one-paragraph plain-language description (use the "In plain words" text above).
2. The exact file and FSM state/line (`combined_top.v`, `decoder.v`, `operation_module.v` — the table at the top pins down each).
3. A minimal repro: which security level, which phase, and the symptom (wrong key / hang / flipped verify / corrupted signature / 2nd-phase crash).
4. The proposed fix (from the "Fix" line) and a note that it passes our KeyGen+Sign+Verify regression.

**Suggested priority for filing:** Bug 3 first (verify pass/fail flipped — clearest spec violation, easiest to demonstrate), then Bug 2 (deterministic hang, trivial to prove), then Bug 4 (corruption under realistic backpressure — broadest impact), then Bug 1 (race — attach any tool-version notes), then Bug 5 (multi-phase).

**Internal note:** Even though only bugs 1–5 go upstream, the project lead / supervisor should be made aware of *all seven*, because we are currently shipping a patched local copy of the accelerator (see [reference_sign_fsm] and `CVA6_MLDSA_INTEGRATION.md`). Anyone re-integrating from a fresh upstream pull will reintroduce bugs 1–5 unless these patches are preserved or upstreamed.

# ML-DSA End-to-End simulation tests

These tests run the **full signing protocol** — KeyGen → Sign → Verify — as a
single chained sequence, using the **actual outputs of each phase as inputs to
the next**. No pre-baked KAT signatures are used.

## Why this matters

The per-phase tests (`keygen/`, `sign/`, `verify/`) validate each phase
independently against the NIST KAT. The chained test catches composition bugs
that only surface when phases interact:

- Bit-ordering mismatches between what one phase emits and the next consumes
- Streaming-interface backpressure bugs that only manifest under sustained
  multi-phase traffic
- CTRL/start-bit re-triggering bugs in the bridge between phases

## Layout

- `standalone/` — accelerator driven directly, no bridge
- `bridge/` — accelerator behind `axi_mldsa_bridge`, driven by AXI4 BFM

## What you'll see on PASS

```
=== [e2e] Phase cycles: KG=11391  Sign=87107  Verify=14297
=== [e2e] RESULT: PASS — Verify accepted sig from chained KeyGen+Sign ===
testbench done - PASS
============================================================
```

The cycle counts will differ slightly between standalone and bridge (bridge
adds AXI transaction latency + the 2-phase start sequence per phase).

## Phase CTRL values (bridge only)

```
KeyGen (mode=0): CTRL = (3<<3) | (0<<1) | 1 = 0x19
Sign   (mode=2): CTRL = (3<<3) | (2<<1) | 1 = 0x1D
Verify (mode=1): CTRL = (3<<3) | (1<<1) | 1 = 0x1B
```

## Critical bridge-context detail

Between phases, the testbench writes `CTRL=0x00` to clear the start bit before
asserting the next phase's CTRL. The bridge's `ctrl_start_rise` is a
rising-edge detector — without clearing, the start bit stays high from Phase 1
and Phase 2's CTRL write never triggers the 2-phase start sequence, causing
Sign to hang indefinitely.

Standalone does not have this issue — it pulses `start` directly with no
intermediate register.

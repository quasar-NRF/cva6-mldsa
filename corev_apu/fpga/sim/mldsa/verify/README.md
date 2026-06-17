<!--
==================================================
Giulio Golinelli - golinelli.giulio13@gmail.com
TUMCREATE QUASAR RESEARCH ENGINEER
Modified: 2026-06-17
This file contains modifications vs. the upstream
CVA6 / ML-DSA-OSH source fork.
==================================================
-->

# ML-DSA Verify simulation tests

Verify checks whether a signature is valid for a given public key and message.
Output is a single 64-bit word where **bit 0 is the fail flag**:

- `0` = signature is **VALID**
- `1` = signature is **INVALID**

## Layout

- `standalone/` — accelerator driven directly via streaming interface
- `bridge/` — accelerator behind `axi_mldsa_bridge`, driven by AXI4 BFM

## What you'll see on PASS

```
=== [Bridge Verify] RESULT: PASS (fail=1 matches expected=1), cycles=11926 ===
testbench done - PASS
```

Note: the default KAT (SigVer KAT#0) expects `fail=1` — i.e. it tests the
rejection path. The e2e chained test (in `sim_bridge/tb_bridge_e2e.sv`) covers
the acceptance path (`fail=0`) by feeding signatures produced by Sign.

## Input stream order (Verify, sec_lvl=3)

```
  4   PK rho
  6   c_tilde       (from signature)
400   z             (from signature)
240   PK t1
  1   mlen+ctxlen
 ~N   message_fmtd  (N = ceil((2 + ctxlen + mlen) / 8))
  8   h             (from signature)
```

Total for the default KAT#0 (mlen=2943, ctxlen=110): 1041 words.

## CTRL register value

```
CTRL = (sec_lvl=3 << 3) | (mode=1 << 1) | start=1 = 0x1B
```

## Verify pipeline (13 FSM states)

```
VY_INIT → LOAD_RHO → LOAD_C → DECODE_Z → NTT_Z → NTT_T1 → NTT_C
        → MULT_AZ  → MULT_CT1 → SUB → INTT → GENW1 → COMPARE
```

The final `VY_COMPARE` state emits the single fail bit.

<!--
==================================================
Giulio Golinelli - golinelli.giulio13@gmail.com
TUMCREATE QUASAR RESEARCH ENGINEER
Modified: 2026-06-17
This file contains modifications vs. the upstream
CVA6 / ML-DSA-OSH source fork.
==================================================
-->

# Verify BRIDGE

Tests the ML-DSA-65 accelerator **with the AXI bridge** in Verify mode.

## Run

```bash
./run.sh
```

## What it does

1. Compiles all sources (accelerator + bridge + pulp-platform AXI).
2. Elaborates `tb_verify_bridge`.
3. The BFM:
   - Pushes 1 word to prime the input FIFO
   - Writes `0x1B` to `CTRL` to start Verify
   - Pushes the remaining ~1040 words (PK + sig + msg + h)
   - Drains `DATA_OUT` for exactly 1 word
4. Compares bit 0 of the result word against the expected fail bit.

## CTRL value

```
CTRL = (sec_lvl=3 << 3) | (mode=1 << 1) | start=1 = 0x1B
```

## Input stream (sec_lvl=3, default KAT#0)

```
  4   PK rho
  6   c_tilde       (from signature)
400   z             (from signature)
240   PK t1
  1   mlen+ctxlen
382   message_fmtd  (varies — KAT#0 has mlen=2943, ctxlen=110)
  8   h             (from signature)
```

Total: 1041 words for KAT#0.

## Output

1 word. Bit 0 is the fail flag (0=valid, 1=invalid).

The testbench uses a `begin : drain_loop ... disable drain_loop; ... end`
block to break out of the AXI drain loop once the single result word arrives.

## Files generated in this dir (gitignored)

- `run.log`, `xsim_output.log`, `xsim.dir/`, `webtalk*`

## Testbench

`tb_verify_bridge.sv` — see header comment for full input/output ordering.

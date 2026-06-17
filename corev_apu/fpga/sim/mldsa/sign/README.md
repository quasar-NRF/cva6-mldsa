<!--
==================================================
Giulio Golinelli - golinelli.giulio13@gmail.com
TUMCREATE QUASAR RESEARCH ENGINEER
Modified: 2026-06-17
This file contains modifications vs. the upstream
CVA6 / ML-DSA-OSH source fork.
==================================================
-->

# ML-DSA Sign simulation tests

Sign produces a 3309-byte signature (414 words) from the secret key, message,
and per-signature randomness.

## Layout

- `standalone/` — accelerator driven directly via streaming interface
- `bridge/` — accelerator behind `axi_mldsa_bridge`, driven by AXI4 BFM

## What you'll see on PASS

```
=== [Bridge Sign] RESULT: SIG wrong=0/3309, cycles=103312 ===
testbench done - PASS
```

## Signature layout (414 words)

```
[  0:  5]  ctilde      (6 words, 48B) — hash challenge
[  6:405]  z           (400 words, 3200B) — L=5 polynomials of 64 words each
[406:413]  h           (8 words, 61B padded) — hint vector
```

## Input stream order (Sign, sec_lvl=3)

The bridge consumes these in this order from DATA_IN:

```
  4   SK rho
  1   mlen+ctxlen (combined into one 64-bit word)
  8   SK tr
  ~N  message_fmtd (N = ceil((2 + ctxlen + mlen) / 8))
  4   SK K
  4   rnd (zeros — fresh randomness would go here)
 80   SK s1
 96   SK s2
312   SK t0
```

## CTRL register value

```
CTRL = (sec_lvl=3 << 3) | (mode=2 << 1) | start=1 = 0x1D
```

## Notable fix in this phase

The T0 decoder had a shift-without-load bug in bridge context (transient FIFO
empty cycles pulled stale bits into output). Fixed in `decoder.v` with a stall
condition plus 24-cycle timeout, plus `FIFO_DEPTH` increased from 128 to 1024
in `axi_mldsa_bridge.sv`. Without these, Sign bridge produces ~19 wrong bytes
in the signature h region.

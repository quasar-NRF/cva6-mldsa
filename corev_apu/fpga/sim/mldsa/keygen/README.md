<!--
==================================================
Giulio Golinelli - golinelli.giulio13@gmail.com
TUMCREATE QUASAR RESEARCH ENGINEER
Modified: 2026-06-17
This file contains modifications vs. the upstream
CVA6 / ML-DSA-OSH source fork.
==================================================
-->

# ML-DSA KeyGen simulation tests

KeyGen produces a public key (PK, 1952 B = 244 words) and secret key (SK,
4032 B = 504 words) from a 256-bit random seed.

## Layout

- `standalone/` — accelerator driven directly via streaming interface
- `bridge/` — accelerator behind `axi_mldsa_bridge`, driven by AXI4 BFM

## What you'll see on PASS

```
=== [Bridge KeyGen] RESULT: PK wrong=0 / 1952, SK wrong=0 / 4032, cycles=11379 ===
testbench done - PASS
```

Or for standalone:
```
testbench done
RESULT: PASS — KeyGen matches KAT byte-for-byte
```

## PK layout (244 words)

```
[  0:  3]  rho         (4 words, 32B) — public seed for matrix A
[  4:243]  t1          (240 words, 1920B) — high bits of t = A·s1 + s2
```

## SK layout (504 words)

```
[  0:  3]  rho         (4 words)
[  4:  7]  K           (4 words, 32B) — rejection sampling key
[  8: 15]  tr          (8 words, 64B) — PRF seed
[ 16: 95]  s1          (80 words, 640B) — short secret polynomials (L=5)
[ 96:191]  s2          (96 words, 768B) — short secret polynomials (K=6)
[192:503]  t0          (312 words, 2496B) — low bits of t (encoded)
```

## CTRL register value

```
CTRL = (sec_lvl=3 << 3) | (mode=0 << 1) | start=1 = 0x19
```

(bridge test only — standalone drives mode/sec_lvl directly)

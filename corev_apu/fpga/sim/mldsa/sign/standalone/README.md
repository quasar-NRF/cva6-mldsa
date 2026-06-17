<!--
==================================================
Giulio Golinelli - golinelli.giulio13@gmail.com
TUMCREATE QUASAR RESEARCH ENGINEER
Modified: 2026-06-17
This file contains modifications vs. the upstream
CVA6 / ML-DSA-OSH source fork.
==================================================
-->

# Sign STANDALONE

Tests the ML-DSA-65 accelerator (`combined_top.v`) in Sign mode, with **no
AXI bridge**. The testbench feeds the secret key + message and reads the
signature back, comparing byte-for-byte against the NIST SigGen KAT.

## Run

```bash
./run.sh           # default: 1 KAT vector
./run.sh 5         # first 5 KAT vectors
```

## What it produces

A 3309-byte signature (414 words):
- `ctilde` (6 words, 48B) — hash challenge
- `z` (400 words, 3200B) — L=5 polynomials
- `h` (8 words, 61B padded) — hint vector

## Pass criterion

Zero `WRONG` byte mismatches vs NIST SigGen KAT.

## Files generated in this dir (gitignored)

- `tb_sign_top_sim.v` — patched testbench (regenerated each run)
- `run.log`, `xsim_output.log`, `xsim.dir/`, `webtalk*`

## Source files exercised

- `ML-DSA-OSH/ref_combined/src/*.v` — accelerator (includes encoder, decoder,
  NTT, polynomial arithmetic)
- `ML-DSA-OSH/ref_combined/src_tb/tb_sign_top.v` — upstream testbench
- `ML-DSA-OSH/KAT/SigGen_sk_65.txt` + `SigGen_message_65.txt` +
  `SigGen_signature_65.txt` etc.

## Note on the `rnd` field

Upstream testbench uses zeros for the per-signature randomness. This makes
the signature deterministic and reproducible against the KAT. A real
deployment would feed cryptographic randomness here.

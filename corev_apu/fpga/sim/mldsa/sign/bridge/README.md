# Sign BRIDGE

Tests the ML-DSA-65 accelerator **with the AXI bridge** in Sign mode. This is
the largest input stream of the three phases (~515 words for the default KAT),
exercising the bridge's input FIFO under sustained traffic.

## Run

```bash
./run.sh
```

## What it does

1. Compiles all sources (accelerator + bridge + pulp-platform AXI).
2. Elaborates `tb_sign_bridge`.
3. The BFM:
   - Pushes the full Sign input stream (see sign/README.md for order)
   - Writes `0x1D` to `CTRL` to start Sign
   - Drains `DATA_OUT` for 414 words, reassembling them into a signature
4. Compares signature byte-for-byte against the NIST SigGen KAT.

## CTRL value

```
CTRL = (sec_lvl=3 << 3) | (mode=2 << 1) | start=1 = 0x1D
```

## Notable bridge-context fix

The input FIFO is `FIFO_DEPTH = 1024` (was 128) so the entire Sign input
stream (~515 words) fits without draining mid-stream. Mid-stream draining
combined with the T0 decoder's shift-without-load bug produced wrong t0
coefficients — see sign/README.md.

## Files generated in this dir (gitignored)

- `run.log`, `xsim_output.log`, `xsim.dir/`, `webtalk*`

## Testbench

`tb_sign_bridge.sv` — see header comment for input/output stream ordering.

# End-to-End BRIDGE

Tests the ML-DSA-65 accelerator **with the AXI bridge** across all three
phases in sequence. An AXI4 master BFM drives `axi_mldsa_bridge`, which is
exactly the runtime path the CVA6 CPU uses when executing the full signing
protocol.

## Run

```bash
./run.sh
```

## What it does

Same logical flow as `standalone/`, but every accelerator interaction goes
through memory-mapped reads/writes at `0x50000000`:

- **Phase 1 — KeyGen**: push 4 seed words to `DATA_IN`, write `CTRL=0x19`,
  drain 744 words from `DATA_OUT`.
- **Phase 2 — Sign**: write `CTRL=0x00` (clear start bit), push 1 word to
  prime FIFO, write `CTRL=0x1D`, push remaining ~514 words, drain 414 words.
- **Phase 3 — Verify**: write `CTRL=0x00`, push 1 word, write `CTRL=0x1B`,
  push remaining ~1040 words, drain 1 word.

## CTRL start-bit clear between phases

The bridge's `ctrl_start_rise` is a rising-edge detector. Phase 1's `CTRL=0x19`
leaves `ctrl_start=1`. Phase 2's `CTRL=0x1D` write doesn't trigger a rising
edge → 2-phase start sequence never fires → Sign hangs forever.

**Fix**: write `CTRL=0x00` between phases to clear the start bit, then write
the next phase's CTRL.

## Memory map

See `keygen/bridge/README.md` for the full register map (same for all phases).

## Pass criterion

`fail == 0` — Verify accepts the signature produced by chained Sign on the
key material produced by chained KeyGen.

## Files generated in this dir (gitignored)

- `run.log`, `xsim_output.log`, `xsim.dir/`, `webtalk*`

## Testbench

`tb_e2e_bridge.sv` — SystemVerilog (uses AXI4 master BFM tasks). See header
comment for full phase sequence and CTRL transition details.

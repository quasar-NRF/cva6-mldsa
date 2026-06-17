# KeyGen BRIDGE

Tests the ML-DSA-65 accelerator **with the AXI bridge** (`axi_mldsa_bridge.sv`)
in KeyGen mode. A minimal AXI4 master BFM in the testbench drives the bridge
exactly as the CVA6 CPU would at runtime.

## Run

```bash
./run.sh
```

## What it does

1. Compiles all sources including pulp-platform AXI + common_cells (for the
   bridge's `axi_to_axi_lite` and `axi_lite_regs`).
2. Elaborates `tb_keygen_bridge` — instantiates bridge + accelerator.
3. The BFM:
   - Writes 4 seed words to `DATA_IN` (0x08)
   - Writes `0x19` to `CTRL` (0x00) to start KeyGen
   - Drains `DATA_OUT` (0x10) for 744 words, routing each to PK or SK buffer
4. Compares PK and SK byte-for-byte against the NIST KAT.

## Memory map (byte offsets, 64-bit aligned)

| Offset | Reg       | Dir | Bits                                                |
|--------|-----------|-----|-----------------------------------------------------|
| 0x00   | CTRL      | WO  | [0]=start  [2:1]=mode  [5:3]=sec_lvl                |
| 0x08   | DATA_IN   | WO  | push 64-bit word to input FIFO                      |
| 0x10   | DATA_OUT  | RO  | pop 64-bit word from output FIFO                    |
| 0x18   | STATUS    | RO  | [0]=in_empty  [2]=out_empty  [6]=busy               |
| 0x20   | DIAG      | RO  | accelerator internal state                          |

## CTRL value

```
CTRL = (sec_lvl=3 << 3) | (mode=0 << 1) | start=1 = 0x19
```

## Output routing (744 words)

```
wr_idx   destination           field
------   ------------------    -----
  0..3   pk[0:3] || sk[0:3]    rho
  4..7   sk[K]                 K
  8..87  sk[s1]                s1 (L=5 polys * 16 words/poly)
 88..183 sk[s2]                s2 (K=6 polys * 16 words/poly)
184..423 pk[t1]                t1 (K=6 polys * 40 words/poly)
424..735 sk[t0]                t0 (K=6 polys * 52 words/poly)
736..743 sk[tr]                tr (sent LAST by accelerator despite SK order)
```

## Files generated in this dir (gitignored)

- `run.log`, `xsim_output.log`, `xsim.dir/`, `webtalk*`

## Testbench

`tb_keygen_bridge.sv` — see header comment for AXI4 BFM task details.

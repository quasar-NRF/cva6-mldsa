# Verify STANDALONE

Tests the ML-DSA-65 accelerator (`combined_top.v`) in Verify mode, with **no
AXI bridge**. The testbench feeds PK + signature + message and reads a single
result word.

## Run

```bash
./run.sh           # default: 1 KAT vector
./run.sh 5         # first 5 KAT vectors
```

## What it produces

A single 64-bit result word. **Bit 0 is the fail flag:**

- `0` = signature VALID
- `1` = signature INVALID

## Pass criterion

The fail bit matches the NIST SigVer KAT expected result.

For the default KAT#0, the expected result is `fail=1` (invalid). This proves
the verify pipeline can correctly **reject** bad signatures. The
bridge-e2e test covers the **accept** path (`fail=0`) by feeding real
signatures produced by Sign.

## Files generated in this dir (gitignored)

- `tb_verify_top_sim.v` — patched testbench (regenerated each run)
- `run.log`, `xsim_output.log`, `xsim.dir/`, `webtalk*`

## Testbench patch

Upstream `tb_verify_top.v` iterates security levels 2→3→5→2 (loop). After the
sec_lvl=3 KAT completes, this script patches the loop transition into a
`$finish` so we only test sec_lvl=3 (matches the rest of the test suite).

## Source files exercised

- `ML-DSA-OSH/ref_combined/src/*.v` — accelerator (verify pipeline)
- `ML-DSA-OSH/ref_combined/src_tb/tb_verify_top.v` — upstream testbench
- `ML-DSA-OSH/KAT/SigVer_pk_65.txt` + `SigVer_signature_65.txt` +
  `SigVer_message_65.txt` + `SigVer_result_65.txt` etc.

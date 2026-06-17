<!--
==================================================
Giulio Golinelli - golinelli.giulio13@gmail.com
TUMCREATE QUASAR RESEARCH ENGINEER
Modified: 2026-06-17
This file contains modifications vs. the upstream
CVA6 / ML-DSA-OSH source fork.
==================================================
-->

# End-to-End STANDALONE

Tests the ML-DSA-65 accelerator (`combined_top.v`) across all three phases in
sequence, with **no AXI bridge**. The testbench drives the streaming interface
directly.

## Run

```bash
./run.sh
```

## What it does

1. **Phase 1 — KeyGen** (mode=0)
   - Pulses `start` with `mode=0`, `sec_lvl=3`
   - Sends 4 seed words (32-byte KAT seed)
   - Receives 744 words → routes into `pk_out` (244 words) and `sk_out` (504 words)

2. **Phase 2 — Sign** (mode=2)
   - Pulses `start` with `mode=2`
   - Sends `sk_out` fields (rho, tr, K, s1, s2, t0) + `rnd` + KAT message
   - Receives 414 words → routes into `sig_out` (z, h, ctilde)

3. **Phase 3 — Verify** (mode=1)
   - Pulses `start` with `mode=1`
   - Sends `pk_out` fields (rho, t1) + `sig_out` fields (ctilde, z, h) + KAT message
   - Receives 1 word → bit 0 = fail flag

## Pass criterion

`fail == 0` — Verify accepts the signature produced by chained Sign on the
key material produced by chained KeyGen.

## Testbench structure

`tb_e2e_standalone.v` uses a **single clocked FSM** with the same default-then-
override pattern as the upstream KAT testbenches
(`ref_combined/src_tb/tb_{keygen,sign,verify}_top.v`):

```verilog
always @(posedge clk) begin
    rst     <= 0;            // defaults
    valid_i <= 0;
    start   <= 0;
    ready_o <= 0;

    case (state)
    S_KG_SEND_RHO: begin      // override only what this state needs
        valid_i <= 1;
        ...
    end
    ...
    endcase
end
```

### Why this pattern (and not a queue-based driver)

An earlier version of this TB used a queue + clocked push/drain driver to
stream inputs and outputs concurrently. That version hung at the Sign phase
because holding `ready_o=1` while streaming inputs (even with `valid_o`
inactive) caused the accelerator's internal FSM to deadlock. The upstream
TBs avoid this by keeping `ready_o=0` during all SEND states and only
asserting it in RECV states. This TB replicates that discipline exactly.

### Inter-phase reset

Each phase begins with `S_*_INIT` which asserts `rst=1` for one cycle, then
`rst=0` for one cycle, then pulses `start`. This matches the upstream TB's
behavior between testvectors.

## Files generated in this dir (gitignored)

- `run.log`, `xsim_output.log`, `xsim.dir/`, `webtalk*`

## Testbench

`tb_e2e_standalone.v` — Verilog (not SystemVerilog, since no AXI BFM needed).
See header comment for full FSM state list and data routing details.

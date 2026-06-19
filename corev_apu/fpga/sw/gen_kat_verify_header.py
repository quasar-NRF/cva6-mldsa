#!/usr/bin/env python3
# ==================================================
# Giulio Golinelli - golinelli.giulio13@gmail.com
# TUMCREATE QUASAR RESEARCH ENGINEER
# Modified: 2026-06-17
# This file contains modifications vs. the upstream
# CVA6 / ML-DSA-OSH source fork.
# ==================================================
"""
TUMCREATE (2026-06-18): Generate mldsa_kat_verify_data_<sec_lvl>.h from NIST KAT files.

Picks a small-mlen valid vector (result=1) so the FPGA verify test runs quickly.
Outputs a C header with arrays sized to match the sec_lvl exactly.

Usage: python3 gen_kat_verify_header.py <sec_lvl> <vector_idx>
   sec_lvl: 2, 3, or 5
   vector_idx: 0-indexed line in SigVer_*.txt files (default: auto-pick smallest valid)
"""

import os
import sys

KAT_DIR = "/home/quasart1/cva6/corev_apu/fpga/src/ML-DSA-OSH/KAT"
OUT_DIR = "/home/quasart1/cva6/corev_apu/fpga/sw"

# FIPS 204 parameters per sec_lvl
PARAMS = {
    2: {"suf": "44", "CTILDE_BYTES": 32,  "z_BYTES": 2304, "h_BYTES": 84,  "PK_T1_BYTES": 1280, "K": 4},
    3: {"suf": "65", "CTILDE_BYTES": 48,  "z_BYTES": 3200, "h_BYTES": 61,  "PK_T1_BYTES": 1920, "K": 6},
    5: {"suf": "87", "CTILDE_BYTES": 64,  "z_BYTES": 4480, "h_BYTES": 83,  "PK_T1_BYTES": 2560, "K": 8},
}

# CTX_BYTES from FIPS 204 — must match mldsa_params.v CTX_BYTES define
CTX_BYTES = 256
# MAX_MLEN — must match MAX_MLEN_<L> in tb_verify_top.v (8192 for all levels)
MAX_MLEN = 8192


def read_lines(path):
    with open(path) as f:
        return [line.strip() for line in f if line.strip()]


def pick_vector(sec_lvl):
    """Find the smallest mlen+ctxlen vector with result=1."""
    p = PARAMS[sec_lvl]
    sufs = ["_pk", "_signature", "_message", "_mlen", "_ctx", "_ctxlen", "_result"]
    files = {s: read_lines(os.path.join(KAT_DIR, f"SigVer{s}_{p['suf']}.txt")) for s in sufs}
    n = len(files["_result"])
    print(f"[INFO] sec_lvl={sec_lvl} has {n} vectors", file=sys.stderr)

    candidates = []
    for i in range(n):
        if files["_result"][i] != "1":
            continue
        mlen = int(files["_mlen"][i], 16)
        ctxlen = int(files["_ctxlen"][i], 16)
        # Filter out malformed vectors
        if mlen == 0 or ctxlen == 0:
            continue
        ctx_hex_len = len(files["_ctx"][i])
        if ctx_hex_len != ctxlen * 2:
            print(f"[WARN] vector {i}: ctxlen={ctxlen} but ctx file has {ctx_hex_len//2} bytes", file=sys.stderr)
            continue
        candidates.append((mlen + ctxlen, i, mlen, ctxlen))
    candidates.sort()
    if not candidates:
        raise RuntimeError(f"No valid verify vector found for sec_lvl={sec_lvl}")
    return candidates[0][1], files


def hex_to_bytes(hex_str):
    """Convert hex string to bytes, padding front with zeros if odd length."""
    if len(hex_str) % 2:
        hex_str = "0" + hex_str
    return bytes.fromhex(hex_str)


def bytes_to_words_MSB_first(data, total_words):
    """Pack bytes into uint64_t words with byte 0 in MSB position. Pads end with zeros."""
    out = []
    for w in range(total_words):
        chunk = data[w*8:(w+1)*8]
        chunk = chunk + b'\x00' * (8 - len(chunk))
        # MSB-first: first byte goes to highest byte position
        val = 0
        for i, b in enumerate(chunk):
            val |= b << (56 - i*8)
        out.append(val)
    return out


def fmt_hex(words, per_line=4):
    """Format uint64 list as C array body."""
    lines = []
    for i in range(0, len(words), per_line):
        chunk = words[i:i+per_line]
        parts = [f"0x{w:016X}ULL" for w in chunk]
        sep = "," if i + per_line < len(words) else ""
        lines.append("    " + ", ".join(parts) + sep)
    return "\n".join(lines)


def generate(sec_lvl, vector_idx=None):
    p = PARAMS[sec_lvl]
    if vector_idx is None:
        vector_idx, files = pick_vector(sec_lvl)
    else:
        sufs = ["_pk", "_signature", "_message", "_mlen", "_ctx", "_ctxlen", "_result"]
        files = {s: read_lines(os.path.join(KAT_DIR, f"SigVer{s}_{p['suf']}.txt")) for s in sufs}

    pk_hex = files["_pk"][vector_idx]
    sig_hex = files["_signature"][vector_idx]
    msg_hex = files["_message"][vector_idx]
    ctx_hex = files["_ctx"][vector_idx]
    mlen = int(files["_mlen"][vector_idx], 16)
    ctxlen = int(files["_ctxlen"][vector_idx], 16)
    result = int(files["_result"][vector_idx])

    print(f"[INFO] sec_lvl={sec_lvl} vector_idx={vector_idx}: mlen={mlen} ctxlen={ctxlen} result={result}", file=sys.stderr)

    # PK layout: rho(32) || t1(PK_T1_BYTES). Total = PK_BYTES.
    PK_BYTES = 32 + p["PK_T1_BYTES"]
    if len(pk_hex) != PK_BYTES * 2:
        raise RuntimeError(f"PK hex len {len(pk_hex)} != expected {PK_BYTES*2}")

    pk_bytes = hex_to_bytes(pk_hex)
    pk_rho_bytes = pk_bytes[:32]
    pk_t1_bytes = pk_bytes[32:]

    # SIG layout: c(CTILDE) || z(z_BYTES) || h(h_BYTES). Padded up to 8-byte boundary at end.
    SIG_BYTES = p["CTILDE_BYTES"] + p["z_BYTES"] + p["h_BYTES"]
    if len(sig_hex) < SIG_BYTES * 2:
        raise RuntimeError(f"SIG hex len {len(sig_hex)} < expected {SIG_BYTES*2}")
    sig_bytes = hex_to_bytes(sig_hex[:SIG_BYTES*2])
    # Pad sig with zeros to next 8-byte boundary
    sig_pad = (8 - (len(sig_bytes) % 8)) % 8
    sig_bytes = sig_bytes + b'\x00' * sig_pad

    sig_c_bytes = sig_bytes[:p["CTILDE_BYTES"]]
    sig_z_bytes = sig_bytes[p["CTILDE_BYTES"]:p["CTILDE_BYTES"] + p["z_BYTES"]]
    sig_h_bytes = sig_bytes[p["CTILDE_BYTES"] + p["z_BYTES"]:]
    sig_h_total_words = (len(sig_h_bytes) + 7) // 8
    sig_h_padded = sig_h_bytes + b'\x00' * (sig_h_total_words*8 - len(sig_h_bytes))

    # FMTD message layout: byte 0=0x00, byte 1=ctxlen, ctx[CTX_BYTES-ctxlen:CTX_BYTES], msg[MAX_MLEN-mlen:MAX_MLEN]
    # In NIST KAT files, msg/ctx are stored raw (no padding). The standalone TB loads them
    # right-aligned into a MAX_MLEN / CTX_BYTES buffer.
    msg_bytes_raw = hex_to_bytes(msg_hex)
    ctx_bytes_raw = hex_to_bytes(ctx_hex)
    if len(msg_bytes_raw) != mlen:
        raise RuntimeError(f"msg bytes {len(msg_bytes_raw)} != mlen {mlen}")
    if len(ctx_bytes_raw) != ctxlen:
        raise RuntimeError(f"ctx bytes {len(ctx_bytes_raw)} != ctxlen {ctxlen}")

    # Build formatted message: 0x00 || ctxlen_byte || ctx || msg
    fmtd = bytes([0x00, ctxlen]) + ctx_bytes_raw + msg_bytes_raw
    fmtd_total_words = (len(fmtd) + 7) // 8
    fmtd_padded = fmtd + b'\x00' * (fmtd_total_words*8 - len(fmtd))

    # Word counts
    SIG_C_WORDS = p["CTILDE_BYTES"] // 8  # always 4, 6, 8 for levels 2, 3, 5
    SIG_Z_WORDS = p["z_BYTES"] // 8
    PK_T1_WORDS = p["PK_T1_BYTES"] // 8
    SIG_H_WORDS = sig_h_total_words
    FMTD_WORDS = fmtd_total_words
    MLEN_WORD = (mlen << 8) | ctxlen  # high byte=mlen, low byte=ctxlen (16-bit packed)
    # Per TB line 295: data_i <= {48'd0, temp_len} where temp_len = mlen + {8'd0, ctxlen}
    # That's mlen concatenated with ctxlen as 16-bit (high=mlen, low=ctxlen) — wait,
    # mlen + {8'd0, ctxlen} is ADDITION not concat. Let me re-check.
    # In Verilog: temp_len = mlen_2[c] + {8'd0, ctxlen_2[c]}. {8'd0, ctxlen} = ctxlen<<8.
    # So temp_len = mlen + ctxlen*256 = mlen + (ctxlen<<8).
    # That puts ctxlen in the high byte 8-15 and mlen in lower bytes. Wait no:
    # mlen can be up to 16 bits, ctxlen up to 8 bits. temp_len = mlen + (ctxlen << 8).
    # If mlen < 256, result = mlen + ctxlen*256 = (ctxlen, mlen) as bytes.
    # If mlen > 256 (which it is for vector 0), they overlap.
    # For our pick: mlen=1, ctxlen=174. temp_len = 1 + 174*256 = 44545 = 0xAE01.
    # Reading bytes MSB-first: 0xAE, 0x01.
    # The C header kat_mlen = 0x00000000000000AFULL = 175 for sec_lvl=3 (mlen=1, ctxlen=174=0xAE):
    #   1 + 174 = 175, not 1 + 174*256 = 44544. So the C header uses PLAIN ADD mlen+ctxlen.
    # But the Verilog uses mlen + (ctxlen<<8). These are different!
    # Let me re-read the Verilog: temp_len = mlen_2[c] + {8'd0, ctxlen_2[c]}
    # {8'd0, ctxlen_2[c]} where ctxlen_2[c] is 8-bit = 0x00_E0 for sec_lvl=2 vector 4.
    # {8'd0, 8'xE0} = 16'h00_E0 = 0x00E0 = 224.
    # So temp_len = mlen + 224 = 1 + 224 = 225 for sec_lvl=2 vector 4.
    # For sec_lvl=3 vector 5: temp_len = 1 + 174 = 175 = 0xAF. ✓ matches existing header.
    # So it IS plain addition: temp_len = mlen + ctxlen. My earlier reading was wrong.
    MLEN_WORD = mlen + ctxlen

    # Convert each section to words
    pk_rho_words = bytes_to_words_MSB_first(pk_rho_bytes, 4)
    pk_t1_words = bytes_to_words_MSB_first(pk_t1_bytes, PK_T1_WORDS)
    sig_c_words = bytes_to_words_MSB_first(sig_c_bytes, SIG_C_WORDS)
    sig_z_words = bytes_to_words_MSB_first(sig_z_bytes, SIG_Z_WORDS)
    sig_h_words = bytes_to_words_MSB_first(sig_h_padded, SIG_H_WORDS)
    fmtd_words = bytes_to_words_MSB_first(fmtd_padded, FMTD_WORDS)

    # Generate header
    out_path = os.path.join(OUT_DIR, f"mldsa_kat_verify_data_{sec_lvl}.h")
    with open(out_path, "w") as f:
        f.write("// ==================================================\n")
        f.write("// Giulio Golinelli - golinelli.giulio13@gmail.com\n")
        f.write("// TUMCREATE QUASAR RESEARCH ENGINEER\n")
        f.write("// Auto-generated: 2026-06-18\n")
        f.write("// ==================================================\n\n")
        f.write(f"// KAT Verify data for ML-DSA-{p['suf']} (sec_lvl={sec_lvl})\n")
        f.write(f"// Source: NIST KAT SigVer_{p['suf']}.txt vector index {vector_idx}\n")
        f.write(f"// mlen={mlen}, ctxlen={ctxlen}, expected_result={result}\n")
        f.write(f"// Word counts: sig_c={SIG_C_WORDS}, sig_z={SIG_Z_WORDS}, pk_t1={PK_T1_WORDS}, sig_h={SIG_H_WORDS}, fmtd={FMTD_WORDS}\n\n")
        f.write("#ifndef MLDSA_KAT_VERIFY_DATA_H\n")
        f.write("#define MLDSA_KAT_VERIFY_DATA_H\n\n")
        f.write("#include <stdint.h>\n\n")

        f.write(f"#define KAT_EXPECTED     {result}ULL\n")
        f.write(f"#define KAT_FMTD_WORDS  {FMTD_WORDS}\n")
        f.write(f"#define KAT_SIG_C_WORDS {SIG_C_WORDS}\n")
        f.write(f"#define KAT_SIG_Z_WORDS {SIG_Z_WORDS}\n")
        f.write(f"#define KAT_PK_T1_WORDS {PK_T1_WORDS}\n")
        f.write(f"#define KAT_SIG_H_WORDS {SIG_H_WORDS}\n\n")

        f.write("static const uint64_t kat_pk_rho[4] = {\n")
        f.write(fmt_hex(pk_rho_words))
        f.write("\n};\n\n")

        f.write(f"static const uint64_t kat_pk_t1[{PK_T1_WORDS}] = {{\n")
        f.write(fmt_hex(pk_t1_words))
        f.write("\n};\n\n")

        f.write(f"static const uint64_t kat_sig_c[{SIG_C_WORDS}] = {{\n")
        f.write(fmt_hex(sig_c_words))
        f.write("\n};\n\n")

        f.write(f"static const uint64_t kat_sig_z[{SIG_Z_WORDS}] = {{\n")
        f.write(fmt_hex(sig_z_words))
        f.write("\n};\n\n")

        f.write(f"static const uint64_t kat_sig_h[{SIG_H_WORDS}] = {{\n")
        f.write(fmt_hex(sig_h_words))
        f.write("\n};\n\n")

        f.write(f"static const uint64_t kat_mlen = 0x{MLEN_WORD:016X}ULL;\n\n")

        f.write(f"static const uint64_t kat_fmtd_msg[{FMTD_WORDS}] = {{\n")
        f.write(fmt_hex(fmtd_words))
        f.write("\n};\n\n")

        f.write("#endif // MLDSA_KAT_VERIFY_DATA_H\n")

    print(f"[OK] wrote {out_path}", file=sys.stderr)
    return out_path


if __name__ == "__main__":
    sec_lvl = int(sys.argv[1]) if len(sys.argv) > 1 else 2
    vector_idx = int(sys.argv[2]) if len(sys.argv) > 2 else None
    if sec_lvl not in PARAMS:
        print(f"Invalid sec_lvl={sec_lvl}, must be 2/3/5", file=sys.stderr)
        sys.exit(1)
    generate(sec_lvl, vector_idx)

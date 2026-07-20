#!/usr/bin/env python3
# -----------------------------------------------------------------------------
# gen_pattern.py
#   Stimulus / golden generator for the BFP-PE (Weight-Stationary) unit.
#
#   Emits, into this directory:
#     input.dat  : one cycle of stimulus per line
#                  "<preload> <w_sign_b> <w_exp> <w_man_b> <a_sign_b> <a_exp> <a_man_b>"
#                  all hex, widths matching the RTL packed buses.
#     golden.dat : one 16-bit hex per line = {o_sign, o_exp[4:0], o_man[9:0]}
#                  = the FP16 accumulator value the RTL holds AFTER that cycle.
#
#   The golden model is a BIT-EXACT re-implementation of INT_MAC + BFP_PKG
#   (LOD / NORM / FP16_ADD), including truncation, flush-to-zero and saturation,
#   so a passing testbench proves the RTL matches this reference exactly.
# -----------------------------------------------------------------------------
import random

# ---- Parameters (mirror include.svh) ----------------------------------------
# Only GSIZE / MAN_W / EXP_W need editing; the datapath widths are DERIVED with
# the same formulas as include.svh, so the model tracks any BFP_GSIZE change.
GSIZE     = 16        # <-- must match `BFP_GSIZE in include.svh
MAN_W     = 3
EXP_W     = 5
EXP_BIAS  = 15
FP16_MAN  = 10
FP16_EXP  = 5

def _clog2(n):
    return (n - 1).bit_length()

PROD_W    = 2 * MAN_W                    # BFP_PROD_W
SPROD_W   = PROD_W + 1                   # BFP_SPROD_W
SUM_W     = SPROD_W + _clog2(GSIZE)      # BFP_SUM_W
MAG_W     = SUM_W - 1                    # BFP_MAG_W : unsigned |dot-product|

MAN_MASK  = (1 << MAN_W) - 1        # 0..7
EXP_MASK  = (1 << EXP_W) - 1        # 0..31
MAG_MASK  = (1 << MAG_W) - 1
SIG_MASK  = (1 << (FP16_MAN + 1)) - 1   # FP16 significand {1,man}, always 11 bits
MAN10     = (1 << FP16_MAN) - 1
EXP5      = (1 << FP16_EXP) - 1

# ---- Bit-exact primitives ----------------------------------------------------
# Two leading-one detectors, matching BFP_PKG: they act on different widths and
# only coincide when GSIZE == 32, so they must stay distinct.
def lod_mag(val):
    """Leading zeros of a MAG_W-bit value (matches BFP_PKG::LOD_MAG)."""
    if val == 0:
        return MAG_W - 1
    return MAG_W - 1 - (val.bit_length() - 1)

def lod_sig(val):
    """Leading zeros of an (FP16_MAN+1)-bit significand (matches BFP_PKG::LOD_SIG)."""
    if val == 0:
        return FP16_MAN
    return FP16_MAN - (val.bit_length() - 1)

def norm(sign, mag, blk_exp):
    """Fixed-point dot product -> FP16 16-bit word (matches BFP_PKG::NORM)."""
    if mag == 0:
        return 0
    lz       = lod_mag(mag)
    norm_mag = (mag << lz) & MAG_MASK
    out_exp  = blk_exp + ((MAG_W - 1) - lz)
    # Left-justify the fraction (MAG_W-1 bits) into the FP16 mantissa field:
    # zero-padded when shorter than FP16_MAN, truncated when longer.
    wide     = norm_mag << FP16_MAN
    man      = (wide >> (MAG_W - 1)) & MAN10
    if out_exp <= 0:                            # underflow -> zero
        return 0
    if out_exp >= (EXP5):                       # overflow  -> saturate (exp==31)
        return (sign << 15) | (EXP5 << 10) | MAN10
    return (sign << 15) | ((out_exp & EXP5) << 10) | man

def fp16_add(A, B):
    """FP16 add (matches BFP_PKG::FP16_ADD). exp==0 denotes zero."""
    A_sign, A_exp, A_man = (A >> 15) & 1, (A >> 10) & EXP5, A & MAN10
    B_sign, B_exp, B_man = (B >> 15) & 1, (B >> 10) & EXP5, B & MAN10

    if A_exp == 0:
        return B
    if B_exp == 0:
        return A

    # ---- Align ----
    if A_exp >= B_exp:
        exp_diff   = (A_exp - B_exp) & EXP5
        result_exp = A_exp
        A_sig = (1 << FP16_MAN) | A_man
        B_sig = ((1 << FP16_MAN) | B_man) >> exp_diff
    else:
        exp_diff   = (B_exp - A_exp) & EXP5
        result_exp = B_exp
        A_sig = ((1 << FP16_MAN) | A_man) >> exp_diff
        B_sig = (1 << FP16_MAN) | B_man

    # ---- Addition ----
    if A_sign == B_sign:
        result_add, result_sign = A_sig + B_sig, A_sign
    elif A_sig >= B_sig:
        result_add, result_sign = A_sig - B_sig, A_sign
    else:
        result_add, result_sign = B_sig - A_sig, B_sign

    result_add &= (1 << (FP16_MAN + 2)) - 1     # 12-bit reg

    # ---- FXP2FP (renormalize) ----
    if (result_add >> (FP16_MAN + 1)) & 1:       # carry overflow
        result_add >>= 1
        result_man = result_add & MAN10
        result_exp = (result_exp + 1) & EXP5
        return (result_sign << 15) | (result_exp << 10) | result_man
    if result_add == 0:                          # exact cancel
        return 0
    lod_shift = lod_sig(result_add & SIG_MASK)
    if result_exp > lod_shift:
        result_add = (result_add << lod_shift) & ((1 << (FP16_MAN + 2)) - 1)
        result_exp = result_exp - lod_shift
        result_man = result_add & MAN10
        return (result_sign << 15) | ((result_exp & EXP5) << 10) | result_man
    return 0                                     # underflow

# ---- INT_MAC + block exponent (bit-exact) -----------------------------------
def dot_norm(w, a):
    """One cycle of INT_MAC -> block exp -> NORM. w/a are dicts of lane lists."""
    s = 0
    for i in range(GSIZE):
        p  = w["man"][i] * a["man"][i]
        ps = w["sign"][i] ^ a["sign"][i]
        s += -p if ps else p
    dp_sign = 1 if s < 0 else 0
    dp_mag  = abs(s)
    blk_exp = w["exp"] + a["exp"] - EXP_BIAS
    return norm(dp_sign, dp_mag, blk_exp)

# ---- Packing helpers ---------------------------------------------------------
def pack_man(mans):
    v = 0
    for i, m in enumerate(mans):
        v |= (m & MAN_MASK) << (i * MAN_W)
    return v

def pack_sign(signs):
    v = 0
    for i, s in enumerate(signs):
        v |= (s & 1) << i
    return v

# ---- Random block builders ---------------------------------------------------
def rand_block(exp=None, sparsity=0.0):
    """A random BFP block. sparsity = fraction of lanes forced to zero mantissa."""
    if exp is None:
        exp = random.randint(0, EXP_MASK)
    man  = [0 if random.random() < sparsity else random.randint(0, MAN_MASK)
            for _ in range(GSIZE)]
    sign = [random.randint(0, 1) for _ in range(GSIZE)]
    return {"exp": exp, "man": man, "sign": sign}

def zero_block():
    return {"exp": 0, "man": [0] * GSIZE, "sign": [0] * GSIZE}

def onehot_block(exp, lane, man, sign):
    b = zero_block()
    b["exp"] = exp
    b["man"][lane]  = man
    b["sign"][lane] = sign
    return b

# ---- Test-group construction -------------------------------------------------
# A "group" = 1 preload cycle (load weight, clear accumulator) followed by
# a stream of activation cycles that accumulate against the stationary weight.
def build_groups():
    groups = []  # each group: (weight_block, [activation_block, ...])

    # --- Directed corner cases ---
    # 1) Zero weight -> every product is zero -> accumulator stays 0.
    groups.append((zero_block(), [rand_block() for _ in range(3)]))
    # 2) Single lane, exact power-of-two product (man=4, exp=15,15 -> value 4.0).
    groups.append((onehot_block(15, 0, 4, 0), [onehot_block(15, 0, 1, 0)]))
    # 3) All lanes max positive magnitude, moderate exponent.
    w = {"exp": 16, "man": [MAN_MASK] * GSIZE, "sign": [0] * GSIZE}
    a = {"exp": 16, "man": [MAN_MASK] * GSIZE, "sign": [0] * GSIZE}
    groups.append((w, [a, a]))
    # 4) Sign cancellation: symmetric +/- lanes -> dot product zero.
    wman  = [random.randint(1, MAN_MASK) for _ in range(GSIZE)]
    wsign = [0] * (GSIZE // 2) + [1] * (GSIZE // 2)
    w = {"exp": 15, "man": wman, "sign": wsign}
    a = {"exp": 15, "man": [1] * GSIZE, "sign": [0] * GSIZE}
    groups.append((w, [a]))
    # 5) Large exponent spread across accumulation (big + tiny addends).
    big   = onehot_block(28, 3, MAN_MASK, 0)
    tiny  = onehot_block(2, 3, 1, 0)
    groups.append((onehot_block(15, 3, MAN_MASK, 0), [big, tiny, big, tiny]))

    # --- Randomized groups ---
    for _ in range(40):
        w = rand_block(sparsity=random.choice([0.0, 0.0, 0.3, 0.6]))
        n = random.randint(1, 8)
        acts = [rand_block(sparsity=random.choice([0.0, 0.0, 0.5])) for _ in range(n)]
        groups.append((w, acts))

    return groups

# ---- Emit --------------------------------------------------------------------
def main():
    random.seed(20260720)
    groups = build_groups()

    fin_lines, gold_lines = [], []
    for w, acts in groups:
        # preload cycle : load weight, clear accumulator (activation = don't care)
        acc = 0
        a0  = zero_block()
        fin_lines.append(fmt_input(1, w, a0))
        gold_lines.append(f"{acc:04x}")
        # accumulate cycles
        for a in acts:
            fp_a = dot_norm(w, a)
            acc  = fp16_add(fp_a, acc)
            fin_lines.append(fmt_input(0, w, a))
            gold_lines.append(f"{acc:04x}")

    with open("input.dat", "w") as f:
        f.write("\n".join(fin_lines) + "\n")
    with open("golden.dat", "w") as f:
        f.write("\n".join(gold_lines) + "\n")

    print(f"[gen_pattern] groups={len(groups)}  cycles={len(fin_lines)}")
    print(f"[gen_pattern] wrote input.dat / golden.dat")

def fmt_input(preload, w, a):
    # Hex field widths follow the packed bus widths so the .dat matches the RTL
    # exactly (avoids "too many digits / truncating" warnings when GSIZE changes).
    sh = (GSIZE + 3) // 4                  # BFP_SIGN_BW hex digits
    mh = (GSIZE * MAN_W + 3) // 4          # BFP_MAN_BW  hex digits
    return (f"{preload:x} "
            f"{pack_sign(w['sign']):0{sh}x} {w['exp']:x} {pack_man(w['man']):0{mh}x} "
            f"{pack_sign(a['sign']):0{sh}x} {a['exp']:x} {pack_man(a['man']):0{mh}x}")

if __name__ == "__main__":
    main()

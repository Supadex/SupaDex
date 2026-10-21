#!/usr/bin/env python3
"""Storage-layout guard for upgradeable contracts (ADR-0010, Edith remediation-3 condition 11).

Keeps the current `uint256[N] __gap` layout (no ERC-7201). It fails on any change that is not an append that
consumes the gap:
  * every snapshot variable (except __gap) must still sit at the same slot and offset, with the same label and type;
  * new variables may only be appended after the last snapshot variable and before __gap;
  * __gap must stay the last variable, and the footprint must not change: the gap ends at the same slot as before,
    so it shrinks by exactly the number of slots the appended variables take.

Usage:
  script/check-storage-layout.py check   [Contract ...]  # compare `forge inspect` against storage-layout/<C>.json
  script/check-storage-layout.py snapshot [Contract ...]  # (re)write snapshots after a reviewed change
  script/check-storage-layout.py self-test                # mutation tests of the checker itself
"""
import json, re, subprocess, sys, copy, os

DEFAULT = ["SupaVault"]
SNAP_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "storage-layout")


def norm_type(t):
    return re.sub(r"\)\d+", ")", t)  # strip AST ids, e.g. t_contract(ICircuitBreaker)1398


def layout(contract):
    out = subprocess.run(["forge", "inspect", contract, "storageLayout", "--json"], check=True,
                         capture_output=True, text=True).stdout
    j = json.loads(out)
    types = j.get("types") or {}
    rows = []
    for e in j["storage"]:
        rows.append({"label": e["label"], "slot": int(e["slot"]), "offset": int(e["offset"]),
                     "type": norm_type(e["type"]), "bytes": int(types.get(e["type"], {}).get("numberOfBytes", 32))})
    return rows


def slots(row):
    return max(1, (row["offset"] + row["bytes"] + 31) // 32)


def compare(old, new):
    errs = []
    og = [r for r in old if r["label"] == "__gap"]
    ng = [r for r in new if r["label"] == "__gap"]
    if len(og) != 1:
        return ["snapshot must contain exactly one __gap"]
    if len(ng) != 1:
        return ["__gap missing or duplicated"]
    if new[-1]["label"] != "__gap":
        errs.append("__gap must be the last variable")
    ov = [r for r in old if r["label"] != "__gap"]
    nv = [r for r in new if r["label"] != "__gap"]
    for i, r in enumerate(ov):
        if i >= len(nv):
            errs.append(f"variable removed: {r['label']}")
            continue
        n = nv[i]
        for k in ("label", "slot", "offset", "type"):
            if n[k] != r[k]:
                errs.append(f"{r['label']}: {k} changed {r[k]!r} -> {n[k]!r}")
    end_old = og[0]["slot"] + slots(og[0])
    end_new = ng[0]["slot"] + slots(ng[0])
    if end_old != end_new:
        errs.append(f"__gap footprint changed: storage ends at slot {end_old} before, {end_new} now "
                    f"(gap must shrink by exactly the slots appended)")
    appended = nv[len(ov):]
    if appended:
        last_old_end = (ov[-1]["slot"] + slots(ov[-1])) if ov else 0
        if appended[0]["slot"] < last_old_end:
            errs.append("appended variable overlaps existing storage")
        if ng[0]["slot"] < appended[-1]["slot"] + slots(appended[-1]):
            errs.append("__gap overlaps appended variables")
    return errs


def snap_path(c):
    return os.path.join(SNAP_DIR, f"{c}.json")


def cmd_check(cs):
    bad = 0
    for c in cs:
        old = json.load(open(snap_path(c)))
        errs = compare(old, layout(c))
        print(f"{c}: {'OK' if not errs else 'FAIL'}")
        for e in errs:
            print("  -", e)
        bad += bool(errs)
    return 1 if bad else 0


def cmd_snapshot(cs):
    os.makedirs(SNAP_DIR, exist_ok=True)
    for c in cs:
        with open(snap_path(c), "w") as f:
            json.dump(layout(c), f, indent=2)
            f.write("\n")
        print("wrote", snap_path(c))
    return 0


def cmd_self_test():
    base = [
        {"label": "owner", "slot": 0, "offset": 0, "type": "t_address", "bytes": 20},
        {"label": "x", "slot": 1, "offset": 0, "type": "t_uint256", "bytes": 32},
        {"label": "__gap", "slot": 2, "offset": 0, "type": "t_array(t_uint256)48_storage", "bytes": 48 * 32},
    ]
    def m(f):
        n = copy.deepcopy(base); f(n); return n
    def gap(n, slot, size):
        n[-1].update(slot=slot, type=f"t_array(t_uint256){size}_storage", bytes=size * 32)
    cases = {
        "identical": (base, True),
        "append-with-gap-shrink": (m(lambda n: (n.insert(2, {"label": "y", "slot": 2, "offset": 0, "type": "t_uint256", "bytes": 32}), gap(n, 3, 47))), True),
        "append-without-gap-shrink": (m(lambda n: (n.insert(2, {"label": "y", "slot": 2, "offset": 0, "type": "t_uint256", "bytes": 32}), gap(n, 3, 48))), False),
        "gap-shrunk-without-append": (m(lambda n: gap(n, 2, 47)), False),
        "reorder": (m(lambda n: (n[0].update(label="x"), n[1].update(label="owner"))), False),
        "type-change": (m(lambda n: n[1].update(type="t_int256")), False),
        "insert-before": (m(lambda n: (n.insert(0, {"label": "z", "slot": 0, "offset": 0, "type": "t_uint256", "bytes": 32}), n[1].update(slot=1), n[2].update(slot=2), gap(n, 3, 47))), False),
        "removed": (m(lambda n: (n.pop(1), gap(n, 1, 49))), False),
        "gap-not-last": (m(lambda n: n.append({"label": "y", "slot": 50, "offset": 0, "type": "t_uint256", "bytes": 32})), False),
        "gap-removed": (m(lambda n: n.pop()), False),
    }
    ok = True
    for name, (new, expect_ok) in cases.items():
        got_ok = not compare(base, new)
        status = "pass" if got_ok == expect_ok else "WRONG"
        ok &= got_ok == expect_ok
        print(f"self-test {name:28s} expect {'accept' if expect_ok else 'reject'}: {status}")
    return 0 if ok else 1


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "check"
    cs = sys.argv[2:] or DEFAULT
    sys.exit({"check": cmd_check, "snapshot": cmd_snapshot}.get(mode, lambda _: cmd_self_test())(cs)
             if mode != "self-test" else cmd_self_test())
